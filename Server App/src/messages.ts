import { db } from "./db.js";
import { hub } from "./hub.js";
import { contentHash, normalizeAddress, now } from "./util.js";
import { nanoid } from "nanoid";

export interface IncomingMessage {
  direction: "in" | "out";
  address: string;
  body: string;
  ts: number;
  type: "sms" | "mms";
  providerId?: string;
}

/**
 * Upsert a batch of messages, deduping by content hash so overlapping
 * backfills from multiple phones never create duplicates. Returns counts
 * and broadcasts newly-accepted messages to connected clients.
 */
export function ingest(sourceDeviceId: string, items: IncomingMessage[]) {
  let accepted = 0;
  let duplicate = 0;
  let suppressed = 0;
  const ts = now();

  const findByHash = db.prepare(`SELECT id FROM message WHERE content_hash = ?`);
  const findTomb = db.prepare(`SELECT content_hash FROM deletion WHERE content_hash = ?`);
  const upsertConv = db.prepare(
    `INSERT INTO conversation (id, address, last_ts, snippet, unread)
     VALUES (@id, @address, @ts, @snippet, @unread)
     ON CONFLICT(id) DO UPDATE SET
       last_ts = MAX(last_ts, excluded.last_ts),
       -- Only the newest message in a thread drives the snippet and unread flag:
       -- a genuinely-new inbound message marks the thread unread and updates the
       -- preview; the user's own outbound send clears unread; a historical
       -- backfill row (never the newest) leaves both untouched.
       snippet = CASE
         WHEN excluded.last_ts >= conversation.last_ts THEN excluded.snippet
         ELSE conversation.snippet
       END,
       unread = CASE
         WHEN excluded.last_ts >= conversation.last_ts THEN excluded.unread
         ELSE conversation.unread
       END`,
  );
  const insertMsg = db.prepare(
    `INSERT INTO message
       (id, conversation_id, direction, address, body, ts, type, provider_id,
        source_device_id, content_hash, status, updated_at)
     VALUES
       (@id, @conversation_id, @direction, @address, @body, @ts, @type, @provider_id,
        @source_device_id, @content_hash, @status, @updated_at)`,
  );

  const accepts: any[] = [];
  const tx = db.transaction((batch: IncomingMessage[]) => {
    for (const m of batch) {
      const hash = contentHash(m);
      if (findByHash.get(hash)) { duplicate++; continue; }
      // Deletion is durable: if this content was deleted on any device, never
      // resurrect it — even if the source phone's provider still holds the SMS
      // and keeps re-pushing it on backfill. (Previously the tombstone was
      // cleared here, which brought deleted messages back.)
      if (findTomb.get(hash)) { suppressed++; continue; }

      const convId = normalizeAddress(m.address);
      upsertConv.run({
        id: convId,
        address: m.address,
        ts: m.ts,
        snippet: m.body.slice(0, 140),
        unread: m.direction === "in" ? 1 : 0,
      });

      const row = {
        id: nanoid(),
        conversation_id: convId,
        direction: m.direction,
        address: m.address,
        body: m.body,
        ts: m.ts,
        type: m.type,
        provider_id: m.providerId ?? null,
        source_device_id: sourceDeviceId,
        content_hash: hash,
        status: "received",
        updated_at: ts,
      };
      insertMsg.run(row);
      accepts.push(row);
      accepted++;
    }
  });
  tx(items);

  // Don't echo the ingested messages back to the device that just pushed them.
  for (const row of accepts) hub.broadcast({ type: "message", message: row }, sourceDeviceId);
  return { accepted, duplicate, suppressed };
}

/** Messages/conversations changed since a cursor (updated_at). Delta sync for clients. */
export function delta(since: number) {
  const messages = db
    .prepare(`SELECT * FROM message WHERE updated_at > ? ORDER BY updated_at ASC LIMIT 2000`)
    .all(since);
  // Deletion tombstones since the cursor so a polling client removes messages
  // that were hard-deleted elsewhere (they no longer appear in `message`).
  const deletions = db
    .prepare(`SELECT content_hash, conversation_id, message_id, ts FROM deletion WHERE ts > ? ORDER BY ts ASC LIMIT 2000`)
    .all(since) as { content_hash: string; conversation_id: string | null; message_id: string | null; ts: number }[];
  // Advance the cursor past whichever stream (messages or deletions) reached
  // furthest, so neither is missed and neither is replayed forever.
  const lastMsg = messages.length ? (messages[messages.length - 1] as any).updated_at : since;
  const lastDel = deletions.length ? deletions[deletions.length - 1].ts : since;
  const cursor = Math.max(since, lastMsg, lastDel);
  // Current per-conversation read state so clients render unread correctly on
  // a fresh pull (the phone's read snapshot is otherwise a live-only broadcast).
  const conversations = db.prepare(`SELECT id, unread FROM conversation`).all();
  return { messages, conversations, deletions, cursor };
}

export function setStatus(messageId: string, status: string) {
  db.prepare(`UPDATE message SET status = ?, updated_at = ? WHERE id = ?`)
    .run(status, now(), messageId);
}

/**
 * Deletion mirror (phone → Mac). The agent sends its current SMS set; any
 * stored message whose identity is no longer present is hard-deleted (spec
 * §3.2 mirror semantics) and a delete is broadcast to clients.
 */
export function reconcile(items: IncomingMessage[]) {
  const alive = new Set(items.map(contentHash));
  const rows = db
    .prepare(`SELECT id, content_hash, conversation_id FROM message`)
    .all() as { id: string; content_hash: string; conversation_id: string }[];
  const del = db.prepare(`DELETE FROM message WHERE id = ?`);
  const deleted: { id: string; content_hash: string; conversation_id: string }[] = [];
  const tx = db.transaction(() => {
    for (const r of rows) {
      if (!alive.has(r.content_hash)) {
        del.run(r.id);
        tombstone.run({ content_hash: r.content_hash, conversation_id: r.conversation_id, message_id: r.id, ts: now() });
        deleted.push({ id: r.id, content_hash: r.content_hash, conversation_id: r.conversation_id });
      }
    }
  });
  tx();
  for (const r of deleted) {
    hub.broadcast({ type: "message_deleted", id: r.id, contentHash: r.content_hash, conversationId: r.conversation_id });
  }
  return { deleted: deleted.length };
}

// Records/refreshes a deletion tombstone. `content_hash` is the cross-device
// identity a polling client matches on to remove its local copy; `message_id`
// is the server nanoid the row had, so an id-keyed client (the Mac) can delete
// durably from a /delta pull even if it missed the realtime frame.
const tombstone = db.prepare(
  `INSERT INTO deletion (content_hash, conversation_id, message_id, ts)
   VALUES (@content_hash, @conversation_id, @message_id, @ts)
   ON CONFLICT(content_hash) DO UPDATE SET
     ts = excluded.ts,
     conversation_id = excluded.conversation_id,
     message_id = COALESCE(excluded.message_id, deletion.message_id)`,
);

/**
 * Client-initiated delete (Mac → server). Removes messages and/or a whole
 * conversation from the server store and broadcasts so other clients update.
 * NOTE: this does NOT touch the phone's SMS store (a non-default app can't
 * write it); the phone keeps its copy. A full re-sync would re-import it.
 */
export function deleteItems(input: {
  messageIds?: string[];
  messageHashes?: string[];
  conversationId?: string;
}, actingDeviceId?: string) {
  let deleted = 0;
  const tx = db.transaction(() => {
    if (input.conversationId) {
      // Tombstone every message in the thread by content_hash so polling
      // clients remove their copies, then drop the messages + conversation.
      const rows = db
        .prepare(`SELECT id, content_hash FROM message WHERE conversation_id = ?`)
        .all(input.conversationId) as { id: string; content_hash: string }[];
      for (const r of rows) {
        tombstone.run({ content_hash: r.content_hash, conversation_id: input.conversationId, message_id: r.id, ts: now() });
      }
      db.prepare(`DELETE FROM message WHERE conversation_id = ?`).run(input.conversationId);
      db.prepare(`DELETE FROM conversation WHERE id = ?`).run(input.conversationId);
      deleted += rows.length;
      hub.broadcast({ type: "conversation_deleted", conversationId: input.conversationId }, actingDeviceId);
    }
    if (input.messageIds?.length) {
      const sel = db.prepare(`SELECT conversation_id, content_hash FROM message WHERE id = ?`);
      const del = db.prepare(`DELETE FROM message WHERE id = ?`);
      for (const id of input.messageIds) {
        const row = sel.get(id) as { conversation_id: string; content_hash: string } | undefined;
        del.run(id);
        if (row) tombstone.run({ content_hash: row.content_hash, conversation_id: row.conversation_id, message_id: id, ts: now() });
        deleted++;
        hub.broadcast({
          type: "message_deleted",
          id,
          contentHash: row?.content_hash ?? null,
          conversationId: row?.conversation_id ?? "",
        }, actingDeviceId);
      }
    }
    if (input.messageHashes?.length) {
      // Delete by cross-device content identity (used by the Android fork, which
      // doesn't store the server's nanoid message ids).
      const sel = db.prepare(`SELECT id, conversation_id FROM message WHERE content_hash = ?`);
      const del = db.prepare(`DELETE FROM message WHERE content_hash = ?`);
      for (const hash of input.messageHashes) {
        const row = sel.get(hash) as { id: string; conversation_id: string } | undefined;
        del.run(hash);
        tombstone.run({ content_hash: hash, conversation_id: row?.conversation_id ?? null, message_id: row?.id ?? null, ts: now() });
        if (row) deleted++;
        hub.broadcast({
          type: "message_deleted",
          id: row?.id ?? "",
          contentHash: hash,
          conversationId: row?.conversation_id ?? "",
        }, actingDeviceId);
      }
    }
  });
  tx();
  console.log(`SMS[diag] delete applied: deleted=${deleted} ids=${input.messageIds?.length ?? 0} hashes=${input.messageHashes?.length ?? 0} conv=${input.conversationId ?? "-"}`);
  return { deleted };
}

/**
 * Apply read-state updates reported by the primary Android agent (phone → Mac
 * read sync). Sets each conversation's unread flag and broadcasts the change so
 * connected clients (the Mac) reflect it live.
 */
export function applyReadUpdates(updates: { address: string; unread: boolean }[], actingDeviceId?: string) {
  if (!updates.length) return;
  // Upsert (not bare UPDATE): a read pushed for a conversation the server hasn't
  // ingested yet is still recorded, so it survives a later /delta pull instead
  // of being silently dropped when the WHERE matched no row.
  const upd = db.prepare(
    `INSERT INTO conversation (id, address, last_ts, snippet, unread)
     VALUES (@id, @id, 0, '', @unread)
     ON CONFLICT(id) DO UPDATE SET unread = excluded.unread`,
  );
  const tx = db.transaction(() => {
    for (const u of updates) {
      const id = normalizeAddress(u.address);
      const info = upd.run({ id, unread: u.unread ? 1 : 0 });
      // SMS[diag]: `matched=0` on an UPDATE would mean the read never landed on a
      // real conversation (address-normalization mismatch). With the upsert this
      // should never be 0; the log confirms reads are persisting server-side.
      console.log(`SMS[diag] read applied: id=${id} unread=${u.unread} changes=${info.changes}`);
      hub.broadcast({ type: "conversation_read", conversationId: id, unread: u.unread }, actingDeviceId);
    }
  });
  tx();
}
