/**
 * Repair an account after the upgrade to per-user databases.
 *
 * Two things the first release of that migration could leave wrong, both
 * one-shot and so not self-correcting on a restart:
 *
 *  1. Device tokens not carried over ("0 device token(s) carried over" in the
 *     log). The migration read the device table through a handle that had been
 *     opened before the database was moved into place, so it saw an empty file.
 *     Every phone and Mac then had to sign in again. Fixed in migrate.ts; this
 *     re-indexes the tokens for an install that already ran the old code.
 *
 *  2. A typo in OWNER_EMAIL. The value is read once, so a second start won't
 *     correct it, and the account is what devices authenticate against.
 *
 * Idempotent: re-indexing an existing token replaces the same row, so running
 * this twice changes nothing. Stop the server first — it caches database
 * handles, and this writes to the registry underneath it.
 *
 *   npm run repair                        # re-index tokens, report state
 *   npm run repair -- you@example.com     # ...and correct the sole account's email
 */
import Database from "better-sqlite3";
import fs from "node:fs";
import path from "node:path";
import { config, paths } from "../src/config.js";
import { listUsers, recordToken } from "../src/users.js";

const newEmail = process.argv[2]?.trim();

const users = listUsers();
if (users.length === 0) {
  console.error(`No accounts in ${paths.registry()}. Nothing to repair.`);
  process.exit(1);
}

if (newEmail) {
  if (!newEmail.includes("@")) {
    console.error(`"${newEmail}" is not an email address.`);
    process.exit(1);
  }
  if (users.length > 1) {
    // Guessing which of several accounts was meant risks pointing someone's
    // devices at another person's messages.
    console.error(
      `${users.length} accounts exist, so which one to rename is ambiguous:\n` +
        users.map((u) => `  ${u.id}  ${u.email}`).join("\n") +
        `\nRename with sqlite3 directly:\n` +
        `  sqlite3 "${paths.registry()}" "UPDATE user SET email='${newEmail}' WHERE id='<id>';"`,
    );
    process.exit(1);
  }
  const registry = new Database(paths.registry());
  const previous = users[0].email;
  registry.prepare(`UPDATE user SET email = ? WHERE id = ?`).run(newEmail, users[0].id);
  registry.close();
  console.log(`Email: "${previous}" -> "${newEmail}"`);
}

// Re-index every account's device tokens into the registry. Reads each user's
// own database directly rather than through userContext(), so a stale cached
// handle cannot be the thing we read from.
let total = 0;
for (const user of listUsers()) {
  const file = path.join(paths.userDir(user.id), "sms.sqlite");
  if (!fs.existsSync(file)) {
    console.warn(`  ${user.email}: no database at ${file} — skipped`);
    continue;
  }

  const db = new Database(file, { readonly: true });
  let devices: { id: string; auth_token_hash: string }[] = [];
  try {
    devices = db.prepare(`SELECT id, auth_token_hash FROM device`).all() as typeof devices;
  } catch (err) {
    // A database that predates the device table, or is not one of ours.
    console.warn(`  ${user.email}: could not read devices (${(err as Error).message})`);
  }

  const messages = (() => {
    try {
      return (db.prepare(`SELECT COUNT(*) AS n FROM message`).get() as { n: number }).n;
    } catch {
      return 0;
    }
  })();
  db.close();

  for (const d of devices) recordToken(user.id, d.id, "", d.auth_token_hash);
  total += devices.length;
  console.log(`  ${user.email}: ${devices.length} device token(s), ${messages} message(s)`);
}

console.log(
  total > 0
    ? `\nRe-indexed ${total} device token(s). Paired devices stay signed in; start the server.`
    : `\nNo device tokens found. If phones were paired before the upgrade, the message ` +
        `counts above will show whether the right database was adopted.`,
);
console.log(`Data dir: ${config.dataDir}`);
