import Database from "better-sqlite3";
import fs from "node:fs";
import path from "node:path";
import { nanoid } from "nanoid";
import { config, paths } from "./config.js";
import { openUserDb } from "./db.js";
import { now, sha256 } from "./util.js";

/**
 * Multi-user support: one family, one server, a separate database per person.
 *
 * Isolation is structural rather than a WHERE clause. Each user gets their own
 * SQLite file and their own media directory, so there is no query that could
 * return another person's messages even if someone forgot a filter — and
 * removing a user is deleting a folder.
 *
 * The registry below is the only shared state: who exists, and which token
 * belongs to whom. It has to be shared, because resolving a token is what tells
 * us which database to open.
 */

fs.mkdirSync(config.dataDir, { recursive: true });

const registry = new Database(paths.registry());
registry.pragma("journal_mode = WAL");
registry.exec(`
CREATE TABLE IF NOT EXISTS user (
  id         TEXT PRIMARY KEY,
  email      TEXT NOT NULL UNIQUE COLLATE NOCASE,
  phone      TEXT,
  created_at INTEGER NOT NULL
);

-- Token -> user index. Device rows live in each user's own database, but a
-- token has to be resolvable before we know which database that is.
CREATE TABLE IF NOT EXISTS device_token (
  token_hash TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
  device_id  TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_device_token_user ON device_token(user_id);

-- Pending sign-ups. The code is stored hashed and expires, so an abandoned
-- attempt can't be completed later.
CREATE TABLE IF NOT EXISTS signup (
  id         TEXT PRIMARY KEY,
  email      TEXT NOT NULL COLLATE NOCASE,
  phone      TEXT NOT NULL,
  code_hash  TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts   INTEGER NOT NULL DEFAULT 0
);
`);

export interface UserRow {
  id: string;
  email: string;
  phone: string | null;
  created_at: number;
}

/** A user's own database and media directory. */
export interface UserContext {
  userId: string;
  db: Database.Database;
  mediaDir: string;
}

const contexts = new Map<string, UserContext>();

/**
 * Open (and cache) a user's context. better-sqlite3 handles are synchronous and
 * cheap to hold, and a family server has a handful of users, so keeping them
 * open avoids reopening the file on every request.
 */
export function userContext(userId: string): UserContext {
  const existing = contexts.get(userId);
  if (existing) return existing;

  const dir = paths.userDir(userId);
  fs.mkdirSync(dir, { recursive: true });
  const mediaDir = path.join(dir, "media");
  fs.mkdirSync(mediaDir, { recursive: true });

  const ctx: UserContext = { userId, db: openUserDb(path.join(dir, "sms.sqlite")), mediaDir };
  contexts.set(userId, ctx);
  return ctx;
}

export function userByEmail(email: string): UserRow | undefined {
  return registry.prepare(`SELECT * FROM user WHERE email = ?`).get(email) as UserRow | undefined;
}

export function userById(id: string): UserRow | undefined {
  return registry.prepare(`SELECT * FROM user WHERE id = ?`).get(id) as UserRow | undefined;
}

export function createUser(email: string, phone: string | null): UserRow {
  const id = nanoid(12);
  registry
    .prepare(`INSERT INTO user (id, email, phone, created_at) VALUES (?, ?, ?, ?)`)
    .run(id, email, phone, now());
  // Create the storage up front so a new account is usable immediately.
  userContext(id);
  return userById(id)!;
}

// ---- tokens ---------------------------------------------------------------

/**
 * [tokenHash] is for the migration of an existing install, where the plaintext
 * token was never ours to begin with — only the hash the device authenticates
 * against. Normal registration passes the token and lets this hash it.
 */
export function recordToken(userId: string, deviceId: string, token: string, tokenHash?: string) {
  registry
    .prepare(`INSERT OR REPLACE INTO device_token (token_hash, user_id, device_id, created_at) VALUES (?, ?, ?, ?)`)
    .run(tokenHash ?? sha256(token), userId, deviceId, now());
}

export function userForToken(token: string): { userId: string; deviceId: string } | undefined {
  const row = registry
    .prepare(`SELECT user_id, device_id FROM device_token WHERE token_hash = ?`)
    .get(sha256(token)) as { user_id: string; device_id: string } | undefined;
  return row ? { userId: row.user_id, deviceId: row.device_id } : undefined;
}

export function revokeTokensFor(userId: string) {
  registry.prepare(`DELETE FROM device_token WHERE user_id = ?`).run(userId);
}

// ---- signup ---------------------------------------------------------------

/** How long a code stays usable, and how many wrong guesses are tolerated. */
const CODE_TTL_MS = 10 * 60 * 1000;
const MAX_ATTEMPTS = 5;

export function startSignup(email: string, phone: string): { challengeId: string; code: string } {
  const challengeId = nanoid();
  // Six digits, zero-padded: it has to be typed and read out of an SMS.
  const code = String(Math.floor(Math.random() * 1_000_000)).padStart(6, "0");
  registry
    .prepare(`INSERT INTO signup (id, email, phone, code_hash, expires_at) VALUES (?, ?, ?, ?, ?)`)
    .run(challengeId, email, phone, sha256(code), now() + CODE_TTL_MS);
  return { challengeId, code };
}

export type VerifyResult =
  | { ok: true; user: UserRow }
  | { ok: false; reason: "unknown" | "expired" | "too_many" | "mismatch" };

export function verifySignup(challengeId: string, code: string): VerifyResult {
  const row = registry.prepare(`SELECT * FROM signup WHERE id = ?`).get(challengeId) as
    | { id: string; email: string; phone: string; code_hash: string; expires_at: number; attempts: number }
    | undefined;
  if (!row) return { ok: false, reason: "unknown" };
  if (row.expires_at < now()) {
    registry.prepare(`DELETE FROM signup WHERE id = ?`).run(challengeId);
    return { ok: false, reason: "expired" };
  }
  if (row.attempts >= MAX_ATTEMPTS) return { ok: false, reason: "too_many" };

  if (sha256(code) !== row.code_hash) {
    registry.prepare(`UPDATE signup SET attempts = attempts + 1 WHERE id = ?`).run(challengeId);
    return { ok: false, reason: "mismatch" };
  }

  registry.prepare(`DELETE FROM signup WHERE id = ?`).run(challengeId);
  const existing = userByEmail(row.email);
  if (existing) {
    // Signing in again from another device: keep the account, refresh the number
    // in case they moved SIM.
    registry.prepare(`UPDATE user SET phone = ? WHERE id = ?`).run(row.phone, existing.id);
    return { ok: true, user: { ...existing, phone: row.phone } };
  }
  return { ok: true, user: createUser(row.email, row.phone) };
}

/** Housekeeping so abandoned attempts don't accumulate. */
export function pruneSignups() {
  registry.prepare(`DELETE FROM signup WHERE expires_at < ?`).run(now());
}

export function listUsers(): UserRow[] {
  return registry.prepare(`SELECT * FROM user ORDER BY created_at ASC`).all() as UserRow[];
}
