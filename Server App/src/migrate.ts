import fs from "node:fs";
import path from "node:path";
import { config, paths } from "./config.js";
import { createUser, listUsers, recordToken, resetContext, userContext } from "./users.js";

/**
 * Adopt an existing single-user install into the multi-user layout.
 *
 * Before this, everything lived in data/sms.sqlite and data/media. Rather than
 * asking the first user to re-sync from their phone — which would lose anything
 * only the server still had — the old files are moved into a real account and
 * every device token already in that database is copied into the registry, so
 * phones and Macs stay signed in and never notice.
 *
 * Runs once. Afterwards the legacy paths no longer exist, so it's a no-op.
 */
export function migrateLegacyInstall(email: string | null): void {
  const legacyDb = paths.legacyDb();
  if (!fs.existsSync(legacyDb)) return;
  if (listUsers().length > 0) {
    // Already migrated (or a fresh multi-user install that happens to have a
    // stale file next to it). Don't touch it.
    return;
  }

  const owner = email?.trim() || "owner@localhost";
  const user = createUser(owner, null);
  const dir = paths.userDir(user.id);
  fs.mkdirSync(dir, { recursive: true });

  // Move the database and its WAL siblings together: leaving the -wal behind
  // would silently discard the most recent writes.
  for (const suffix of ["", "-wal", "-shm"]) {
    const from = `${legacyDb}${suffix}`;
    if (fs.existsSync(from)) fs.renameSync(from, path.join(dir, `sms.sqlite${suffix}`));
  }

  const legacyMedia = paths.legacyMedia();
  const newMedia = path.join(dir, "media");
  if (fs.existsSync(legacyMedia)) {
    fs.renameSync(legacyMedia, newMedia);
  } else {
    fs.mkdirSync(newMedia, { recursive: true });
  }

  // createUser() opened an empty database at the destination path before the
  // renames above replaced the file. That cached handle now points at an
  // unlinked inode, so reading the device table through it returns nothing and
  // every later write in this process disappears. Drop it and reopen the file
  // that is actually on disk.
  resetContext(user.id);

  // Re-index the tokens those devices are already using, so nothing has to be
  // re-paired. The hashes come across as-is; we never held the plaintext.
  const ctx = userContext(user.id);
  const devices = ctx.db.prepare(`SELECT id, auth_token_hash FROM device`).all() as {
    id: string;
    auth_token_hash: string;
  }[];
  for (const d of devices) recordToken(user.id, d.id, "", d.auth_token_hash);

  console.log(
    `Migrated the existing single-user install into account "${owner}" ` +
      `(${devices.length} device token(s) carried over). Data now lives in ${dir}`,
  );
}

/** Where the legacy data would have been, for the log line at startup. */
export function legacyDataPresent(): boolean {
  return fs.existsSync(paths.legacyDb()) && fs.existsSync(config.dataDir);
}
