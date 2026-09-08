/**
 * Re-key existing rows onto one canonical address form.
 *
 * Why this exists: both the conversation id and the content hash were derived
 * from the address exactly as it arrived, so one person had two identities.
 * Texting "916309003" and getting the reply back as "+351916309003" (what the
 * carrier actually does) produced two threads and two different hashes for the
 * same message. Since the content hash *is* cross-device identity, a delete on
 * the Mac could not be matched on Android.
 *
 * The server now keys on canonicalAddress(). This brings the rows already
 * stored into line: conversation ids recomputed and merged, content hashes
 * recomputed from the canonical address (attachments included, so MMS identity
 * survives).
 *
 * Read this before running it:
 *
 *  - It rewrites the conversation and message tables. Back up the data dir.
 *  - Dry run by default. Nothing is written without --apply.
 *  - Stop the server first. It holds cached database handles and would be
 *    writing underneath this.
 *  - Update every client before syncing again. Clients recompute hashes
 *    locally; an older build computes the previous hash and won't match, which
 *    is the same failure in reverse.
 *  - Rows that collapse to one hash were the same message stored twice under
 *    two address formats. The oldest is kept and the duplicates deleted, which
 *    is the point of the exercise, but it is a delete: hence the backup. Each
 *    one is tombstoned under the identity it had, so a client holding the
 *    duplicate (the Mac, which showed two bubbles for a self-sent message)
 *    drops it on the next sync instead of keeping it forever.
 *  - Tombstones keep their old hashes and are left alone. Anything already
 *    deleted stays deleted (it is gone from `message`), but a full re-backfill
 *    from a phone would no longer be suppressed by those tombstones. The
 *    address they were hashed from is no longer stored, so they cannot be
 *    recomputed.
 *
 *   npm run canonicalise            # report what would change
 *   npm run canonicalise -- --apply # write it
 */
import Database from "better-sqlite3";
import fs from "node:fs";
import path from "node:path";
import { paths } from "../src/config.js";
import { callingCodeOf, listUsers } from "../src/users.js";
import { canonicalAddress, contentHash } from "../src/util.js";

const apply = process.argv.includes("--apply");

interface MessageRow {
  id: string;
  conversation_id: string;
  direction: string;
  address: string;
  body: string;
  ts: number;
  type: string;
  content_hash: string;
}

interface ConversationRow {
  id: string;
  address: string;
  display_name: string | null;
  last_ts: number;
  snippet: string | null;
  unread: number;
}

function migrate(userId: string, email: string, phone: string | null) {
  const file = path.join(paths.userDir(userId), "sms.sqlite");
  if (!fs.existsSync(file)) {
    console.log(`  ${email}: no database, skipped`);
    return;
  }

  const defaultCc = callingCodeOf(phone);
  if (!defaultCc) {
    // Without the account's own country code a national address cannot be
    // resolved, so this would be a no-op for exactly the rows that need it.
    console.log(`  ${email}: country code unknown (phone: ${phone ?? "none"}) — skipped`);
    return;
  }

  const db = new Database(file);
  db.pragma("journal_mode = WAL");
  // Deliberately OFF. message.conversation_id is ON DELETE CASCADE, so pruning
  // a superseded conversation row with enforcement on would take its messages
  // with it. Every message is re-pointed at a canonical conversation that this
  // script inserts first, so referential integrity holds at the end regardless.
  db.pragma("foreign_keys = OFF");

  const messages = db
    .prepare(
      `SELECT id, conversation_id, direction, address, body, ts, type, content_hash
         FROM message ORDER BY ts ASC`,
    )
    .all() as MessageRow[];

  // Media identity is part of the hash for MMS, so it has to be folded back in
  // or every MMS would be re-keyed to a text-only hash.
  const mediaFor = new Map<string, { sha256: string }[]>();
  for (const a of db.prepare(`SELECT message_id, sha256 FROM attachment`).all() as {
    message_id: string;
    sha256: string;
  }[]) {
    const list = mediaFor.get(a.message_id) ?? [];
    list.push({ sha256: a.sha256 });
    mediaFor.set(a.message_id, list);
  }

  let convChanged = 0;
  let hashChanged = 0;
  const plan: { id: string; conversation_id: string; content_hash: string }[] = [];
  // First writer wins: messages are ordered oldest-first, so the surviving copy
  // of a duplicated pair is the one that arrived first.
  const keptByHash = new Map<string, string>();
  const duplicates: { id: string; oldHash: string; conversation_id: string }[] = [];

  for (const m of messages) {
    const canonical = canonicalAddress(m.address, defaultCc);
    const newHash = contentHash({
      address: m.address,
      type: m.type,
      body: m.body,
      ts: m.ts,
      direction: m.direction,
      attachments: mediaFor.get(m.id),
      defaultCc,
    });

    if (canonical !== m.conversation_id) convChanged++;
    if (newHash !== m.content_hash) hashChanged++;

    if (keptByHash.has(newHash)) {
      duplicates.push({ id: m.id, oldHash: m.content_hash, conversation_id: canonical });
      continue;
    }
    keptByHash.set(newHash, m.id);
    plan.push({ id: m.id, conversation_id: canonical, content_hash: newHash });
  }

  // Merge the conversation rows onto canonical keys, keeping the metadata of
  // the most recent row of each group so the merged thread looks like the one
  // actually in use.
  const convRows = db
    .prepare(`SELECT id, address, display_name, last_ts, snippet, unread FROM conversation ORDER BY last_ts ASC`)
    .all() as ConversationRow[];

  const merged = new Map<string, ConversationRow>();
  const note = (key: string, row: ConversationRow) => {
    const existing = merged.get(key);
    if (!existing || row.last_ts >= existing.last_ts) {
      merged.set(key, {
        ...row,
        id: key,
        address: key,
        // A contact name lives on whichever row happened to be created by the
        // client that knew it, which is not necessarily the most recent one.
        // Carry it in either direction rather than letting the merge drop it.
        display_name: row.display_name ?? existing?.display_name ?? null,
        last_ts: Math.max(row.last_ts, existing?.last_ts ?? 0),
      });
    } else if (!existing.display_name && row.display_name) {
      existing.display_name = row.display_name;
    }
  };
  for (const r of convRows) {
    const key = canonicalAddress(r.address || r.id, defaultCc);
    if (key) note(key, r);
  }
  // A thread a message points at but that has no conversation row of its own
  // (possible once ids move) still needs a parent.
  for (const p of plan) {
    if (!merged.has(p.conversation_id)) {
      note(p.conversation_id, {
        id: p.conversation_id,
        address: p.conversation_id,
        display_name: null,
        last_ts: 0,
        snippet: null,
        unread: 0,
      });
    }
  }

  console.log(
    `  ${email}: ${messages.length} message(s), cc +${defaultCc}\n` +
      `      conversation id changes: ${convChanged}\n` +
      `      content hash changes:    ${hashChanged}\n` +
      `      conversations: ${convRows.length} -> ${merged.size}\n` +
      `      duplicates to remove:    ${duplicates.length}`,
  );

  if (!apply) {
    db.close();
    return;
  }

  const tx = db.transaction(() => {
    const insConv = db.prepare(
      `INSERT INTO conversation (id, address, display_name, last_ts, snippet, unread)
       VALUES (@id, @address, @display_name, @last_ts, @snippet, @unread)
       ON CONFLICT(id) DO UPDATE SET
         address      = excluded.address,
         display_name = COALESCE(excluded.display_name, conversation.display_name),
         last_ts      = MAX(excluded.last_ts, conversation.last_ts),
         snippet      = COALESCE(excluded.snippet, conversation.snippet),
         unread       = excluded.unread`,
    );
    for (const c of merged.values()) insConv.run(c);

    // content_hash carries a UNIQUE index, and a row's new hash can collide
    // with another row's not-yet-updated old hash. Dropping the index for the
    // rewrite avoids a spurious constraint failure on an ordering accident;
    // it goes back on below, which also asserts the result is actually unique.
    db.exec(`DROP INDEX IF EXISTS idx_message_hash`);

    // Tombstone each duplicate so clients holding a copy drop it: the Mac
    // deletes by message_id, Android by content hash.
    //
    // The hash needs care. A duplicate's old hash is frequently the very hash
    // the survivor now carries — that is what "duplicate" means here — and
    // tombstoning that would tell every client the *surviving* message is
    // deleted. So in that case the tombstone gets a synthetic key instead:
    // nothing can collide with it (real hashes are 64 hex characters), the Mac
    // still finds its row by message_id, and a hash-matching client correctly
    // finds nothing to remove.
    const surviving = new Set(plan.map((p) => p.content_hash));
    const tomb = db.prepare(
      `INSERT INTO deletion (content_hash, conversation_id, message_id, ts)
       VALUES (@content_hash, @conversation_id, @message_id, @ts)
       ON CONFLICT(content_hash) DO UPDATE SET ts = excluded.ts`,
    );
    const delMsg = db.prepare(`DELETE FROM message WHERE id = ?`);
    const stamp = Date.now();
    for (const d of duplicates) {
      const key = d.oldHash && !surviving.has(d.oldHash) ? d.oldHash : `dup:${d.id}`;
      tomb.run({
        content_hash: key,
        conversation_id: d.conversation_id,
        message_id: d.id,
        ts: stamp,
      });
      delMsg.run(d.id);
    }

    const upd = db.prepare(
      `UPDATE message SET conversation_id = @conversation_id, content_hash = @content_hash WHERE id = @id`,
    );
    for (const p of plan) upd.run(p);

    db.exec(`CREATE UNIQUE INDEX IF NOT EXISTS idx_message_hash ON message(content_hash)`);

    // Drop the now-superseded thread rows. Safe only because foreign_keys is
    // off and every message above was re-pointed at a surviving conversation.
    const live = [...merged.keys()];
    const placeholders = live.map(() => "?").join(",");
    db.prepare(`DELETE FROM conversation WHERE id NOT IN (${placeholders})`).run(...live);
  });

  tx();

  const orphans = db
    .prepare(`SELECT COUNT(*) AS n FROM message WHERE conversation_id NOT IN (SELECT id FROM conversation)`)
    .get() as { n: number };
  db.close();

  console.log(`      applied${orphans.n ? ` — WARNING: ${orphans.n} orphaned message(s)` : ""}`);
}

const users = listUsers();
if (!users.length) {
  console.error(`No accounts in ${paths.registry()}.`);
  process.exit(1);
}

console.log(apply ? "Applying canonical addresses:" : "Dry run (pass --apply to write):");
for (const u of users) migrate(u.id, u.email, u.phone);
console.log(
  apply
    ? "\nDone. Restart the server, then update every client before it syncs —\n" +
        "an older build computes the previous hash and won't match."
    : "\nNothing written.",
);
