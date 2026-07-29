/**
 * One-off maintenance: consolidate duplicate conversations that represent the
 * same contact stored under different address formats (e.g. "+351912388343",
 * "351912388343" and national "912388343"). These duplicates come from the
 * Android client canonicalizing the same number inconsistently over time, and
 * they break read/delete sync because the update lands on one variant while the
 * client shows another.
 *
 * What it does, per group of same-contact conversations:
 *   1. Picks a canonical E.164 id (existing "+CC…" form if present, otherwise
 *      builds "+<DEFAULT_CC><national>" for a bare national number).
 *   2. Re-points every message to the canonical conversation, rewriting each
 *      message's address + content_hash to the canonical form.
 *   3. De-duplicates messages that are the same SMS under different formats
 *      (same direction + body + 10s time bucket), keeping the earliest.
 *   4. Recomputes the canonical conversation's last_ts / snippet / unread from
 *      its most recent message, and deletes the now-empty duplicate rows.
 *
 * SAFETY:
 *   - Dry-run by default. It only writes when you pass  --apply.
 *   - Before writing it copies the DB to  <db>.bak-<timestamp>.
 *   - All writes happen inside a single transaction.
 *
 * USAGE (from the Server App folder):
 *   npx tsx scripts/consolidate-contacts.ts                 # dry-run report
 *   npx tsx scripts/consolidate-contacts.ts --apply         # actually merge
 *   SMS_DB=/path/to/sms.sqlite npx tsx scripts/consolidate-contacts.ts --apply
 *
 * After applying: reset & re-sync the Mac client (so it drops the old-id
 * threads and re-pulls the canonical ones), and run a rebuilt Android app so
 * new messages are keyed consistently going forward.
 */
import Database from "better-sqlite3";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

// Default country code used to promote a bare national number to E.164.
// Portugal = 351. Change if your SIM is in another country.
const DEFAULT_CC = process.env.DEFAULT_CC ?? "351";
// Length of a national subscriber number for DEFAULT_CC (PT = 9).
const NATIONAL_LEN = Number(process.env.NATIONAL_LEN ?? "9");

const APPLY = process.argv.includes("--apply");
const DB_PATH = process.env.SMS_DB ?? path.join("data", "sms.sqlite");

function normalizeAddress(addr: string): string {
  const trimmed = (addr ?? "").trim();
  const plus = trimmed.startsWith("+") ? "+" : "";
  return plus + trimmed.replace(/[^\d]/g, "");
}

function contentHash(p: { address: string; type: string; body: string; ts: number; direction: string }): string {
  const bucket = Math.round(p.ts / 10000);
  return crypto
    .createHash("sha256")
    .update([normalizeAddress(p.address), p.type, p.direction, p.body.trim(), String(bucket)].join("|"))
    .digest("hex");
}

/**
 * Canonical E.164 for a conversation id, or null if the id isn't a phone number
 * we should touch (short codes, alphanumeric senders, empty ids are left alone).
 */
function canonicalId(id: string): string | null {
  if (/[A-Za-z@]/.test(id)) return null;          // alphanumeric sender / email
  const digits = id.replace(/[^\d]/g, "");
  if (digits.length < 7) return null;             // short code (e.g. 16910) — leave as-is
  if (id.startsWith("+")) return "+" + digits;    // already international
  if (digits.length === NATIONAL_LEN) return `+${DEFAULT_CC}${digits}`; // bare national
  if (digits.startsWith(DEFAULT_CC) && digits.length === DEFAULT_CC.length + NATIONAL_LEN) return "+" + digits;
  return "+" + digits;                            // has a country code but no "+"
}

interface ConvRow { id: string; unread: number; last_ts: number; snippet: string | null; address: string; }
interface MsgRow {
  id: string; conversation_id: string; direction: string; address: string; body: string;
  ts: number; type: string; content_hash: string; updated_at: number;
}

const db = new Database(DB_PATH);
db.pragma("foreign_keys = ON");

const convs = db.prepare(`SELECT id, unread, last_ts, snippet, address FROM conversation`).all() as ConvRow[];

// Group conversations by their canonical id.
const groups = new Map<string, ConvRow[]>();
for (const c of convs) {
  const canon = canonicalId(c.id);
  if (!canon) continue;
  (groups.get(canon) ?? groups.set(canon, []).get(canon)!).push(c);
}

// Only groups that actually change (more than one row, or a single row whose id
// isn't already canonical) need work.
const toMerge = [...groups.entries()].filter(
  ([canon, rows]) => rows.length > 1 || rows[0].id !== canon,
);

console.log(`DB: ${DB_PATH}`);
console.log(`Conversations: ${convs.length}   Groups needing consolidation: ${toMerge.length}`);
for (const [canon, rows] of toMerge) {
  console.log(`  ${canon}  <=  ${rows.map((r) => `${r.id}(unread=${r.unread})`).join(", ")}`);
}
if (toMerge.length === 0) { console.log("Nothing to consolidate."); db.close(); process.exit(0); }

if (!APPLY) {
  console.log("\nDRY RUN — no changes written. Re-run with --apply to perform the merge.");
  db.close();
  process.exit(0);
}

// Backup before writing.
for (const suffix of ["", "-wal", "-shm"]) {
  const f = DB_PATH + suffix;
  if (fs.existsSync(f)) fs.copyFileSync(f, `${f}.bak-${Date.now()}`);
}

const getMsgs = db.prepare(
  `SELECT id, conversation_id, direction, address, body, ts, type, content_hash, updated_at
   FROM message WHERE conversation_id = ?`,
);
const upsertCanonConv = db.prepare(
  `INSERT INTO conversation (id, address, last_ts, snippet, unread)
   VALUES (@id, @address, @last_ts, @snippet, @unread)
   ON CONFLICT(id) DO UPDATE SET last_ts=excluded.last_ts, snippet=excluded.snippet, unread=excluded.unread`,
);
const delMsg = db.prepare(`DELETE FROM message WHERE id = ?`);
const moveMsg = db.prepare(
  `UPDATE message SET conversation_id=@cid, address=@address, content_hash=@hash WHERE id=@id`,
);
const delConv = db.prepare(`DELETE FROM conversation WHERE id = ?`);

let mergedConvs = 0, movedMsgs = 0, dedupedMsgs = 0, removedConvs = 0;

const run = db.transaction(() => {
  for (const [canon, rows] of toMerge) {
    const variantIds = rows.map((r) => r.id);

    // Gather every message across the variants (plus any already under canon).
    const ids = new Set(variantIds);
    ids.add(canon);
    const msgs: MsgRow[] = [];
    for (const cid of ids) msgs.push(...(getMsgs.all(cid) as MsgRow[]));

    // Group by the NEW (canonical) content hash; keep the earliest per group.
    const byHash = new Map<string, MsgRow[]>();
    for (const m of msgs) {
      const h = contentHash({ address: canon, type: m.type, body: m.body, ts: m.ts, direction: m.direction });
      (byHash.get(h) ?? byHash.set(h, []).get(h)!).push(m);
    }
    // Ensure the canonical conversation row exists before moving messages into it.
    const newest = rows.reduce((a, b) => (b.last_ts > a.last_ts ? b : a));
    upsertCanonConv.run({ id: canon, address: canon, last_ts: newest.last_ts, snippet: newest.snippet ?? "", unread: newest.unread });

    // Delete duplicates first (avoids UNIQUE(content_hash) collisions), then
    // rewrite the survivors onto the canonical id/address/hash.
    for (const [h, group] of byHash) {
      group.sort((a, b) => a.ts - b.ts || a.updated_at - b.updated_at);
      const keep = group[0];
      for (const dup of group.slice(1)) { delMsg.run(dup.id); dedupedMsgs++; }
      if (keep.content_hash !== h || keep.conversation_id !== canon || keep.address !== canon) {
        moveMsg.run({ id: keep.id, cid: canon, address: canon, hash: h });
        movedMsgs++;
      }
    }

    // Recompute the canonical conversation's aggregates from its final messages.
    const agg = db.prepare(
      `SELECT MAX(ts) AS last_ts,
              (SELECT body FROM message WHERE conversation_id=? ORDER BY ts DESC LIMIT 1) AS snippet
         FROM message WHERE conversation_id=?`,
    ).get(canon, canon) as { last_ts: number | null; snippet: string | null };
    db.prepare(`UPDATE conversation SET last_ts=?, snippet=? WHERE id=?`)
      .run(agg.last_ts ?? newest.last_ts, (agg.snippet ?? newest.snippet ?? "").slice(0, 140), canon);

    // Drop the now-empty duplicate conversation rows.
    for (const vid of variantIds) if (vid !== canon) { delConv.run(vid); removedConvs++; }
    mergedConvs++;
  }
});

run();
db.close();
console.log(`\nDONE. Consolidated ${mergedConvs} contact(s): moved ${movedMsgs} message(s), removed ${dedupedMsgs} duplicate message(s), deleted ${removedConvs} duplicate conversation row(s).`);
console.log("Backups written next to the DB (*.bak-*). Now reset & re-sync the Mac client.");
