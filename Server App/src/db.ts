import Database from "better-sqlite3";
import fs from "node:fs";
import { config, paths } from "./config.js";

/**
 * Single SQLite connection for the whole process. better-sqlite3 is
 * synchronous, which is exactly what a single-node Mac-mini relay wants:
 * no connection pool, no async races over the message table.
 */
fs.mkdirSync(config.dataDir, { recursive: true });
fs.mkdirSync(paths.media(), { recursive: true });

export const db = new Database(paths.db());
db.pragma("journal_mode = WAL");
db.pragma("foreign_keys = ON");

db.exec(`
CREATE TABLE IF NOT EXISTS device (
  id              TEXT PRIMARY KEY,
  label           TEXT NOT NULL DEFAULT '',
  platform        TEXT NOT NULL DEFAULT 'android',   -- android | mac | ipad
  sim_present     INTEGER NOT NULL DEFAULT 0,
  sim_key         TEXT,                              -- subscriber number / ICCID
  is_primary      INTEGER NOT NULL DEFAULT 0,
  auth_token_hash TEXT NOT NULL,
  last_seen       INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS conversation (
  id           TEXT PRIMARY KEY,                     -- normalized address (or thread key)
  address      TEXT NOT NULL,
  display_name TEXT,
  last_ts      INTEGER NOT NULL DEFAULT 0,
  snippet      TEXT,
  unread       INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS message (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
  direction       TEXT NOT NULL,                     -- in | out
  address         TEXT NOT NULL,
  body            TEXT NOT NULL DEFAULT '',
  ts              INTEGER NOT NULL,
  type            TEXT NOT NULL DEFAULT 'sms',        -- sms | mms
  provider_id     TEXT,                              -- Telephony _id on the source device
  source_device_id TEXT,
  content_hash    TEXT NOT NULL,                     -- cross-device dedup key
  status          TEXT NOT NULL DEFAULT 'received',   -- received | queued | sent | delivered | failed
  updated_at      INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_message_hash ON message(content_hash);
CREATE INDEX IF NOT EXISTS idx_message_conv_ts ON message(conversation_id, ts);
CREATE INDEX IF NOT EXISTS idx_message_updated ON message(updated_at);

CREATE TABLE IF NOT EXISTS attachment (
  id         TEXT PRIMARY KEY,
  message_id TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  mime       TEXT NOT NULL,
  path       TEXT NOT NULL,                          -- content-addressed filename (sha256) under data/media
  size       INTEGER NOT NULL DEFAULT 0,
  sha256     TEXT NOT NULL,
  name       TEXT                                    -- original filename, if any
);
CREATE INDEX IF NOT EXISTS idx_attachment_message ON attachment(message_id);
CREATE INDEX IF NOT EXISTS idx_attachment_sha ON attachment(sha256);

CREATE TABLE IF NOT EXISTS send_request (
  id               TEXT PRIMARY KEY,
  "to"             TEXT NOT NULL,
  body             TEXT NOT NULL,
  requested_by     TEXT NOT NULL,
  target_device_id TEXT,
  status           TEXT NOT NULL DEFAULT 'queued',    -- queued | sent | delivered | failed
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);

-- Deletion tombstones. Hard-deletes vanish from the message table, so a polling
-- client (GET /delta) cannot otherwise learn a message was removed. We record
-- the deleted message content_hash here with a monotonically-increasing ts so
-- delta can return deletions since a cursor and every device converges.
CREATE TABLE IF NOT EXISTS deletion (
  content_hash    TEXT PRIMARY KEY,                   -- cross-device identity of the removed message
  conversation_id TEXT,
  message_id      TEXT,                               -- server nanoid the message had (lets id-keyed clients like the Mac delete durably via /delta)
  ts              INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_deletion_ts ON deletion(ts);
`);

// Migration for databases created before `deletion.message_id` existed:
// add the column if it isn't there yet. (CREATE TABLE IF NOT EXISTS above
// never alters an existing table.)
const deletionCols = db.prepare(`PRAGMA table_info(deletion)`).all() as { name: string }[];
if (!deletionCols.some((c) => c.name === "message_id")) {
  db.exec(`ALTER TABLE deletion ADD COLUMN message_id TEXT`);
}

// Migration: add attachment.name to databases created before it existed.
const attachmentCols = db.prepare(`PRAGMA table_info(attachment)`).all() as { name: string }[];
if (attachmentCols.length && !attachmentCols.some((c) => c.name === "name")) {
  db.exec(`ALTER TABLE attachment ADD COLUMN name TEXT`);
}
