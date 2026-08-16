import fs from "node:fs";
import path from "node:path";
import { sha256 } from "./util.js";
import type { UserContext } from "./users.js";

/**
 * Content-addressed blob store for MMS media. Files live under each user's own
 * media directory, named by their sha256, so identical media shared across a
 * user's messages and devices is stored once.
 *
 * Per-user rather than one shared store: two people can hold the same picture,
 * and a shared store would mean one account could fetch another's blob just by
 * knowing (or guessing) a hash. Duplicating a few files is the cheaper trade.
 */

const HEX64 = /^[a-f0-9]{64}$/;

/** True if `hash` is a well-formed sha256 hex string (guards path traversal). */
export function isValidHash(hash: string): boolean {
  return HEX64.test(hash);
}

export function mediaPath(ctx: UserContext, hash: string): string {
  return path.join(ctx.mediaDir, hash);
}

/** Store bytes, returning the content hash + size. Idempotent (dedup by hash). */
export function storeMedia(ctx: UserContext, buf: Buffer): { sha256: string; size: number } {
  const hash = sha256(buf);
  const p = mediaPath(ctx, hash);
  if (!fs.existsSync(p)) fs.writeFileSync(p, buf);
  return { sha256: hash, size: buf.length };
}

export function mediaExists(ctx: UserContext, hash: string): boolean {
  return isValidHash(hash) && fs.existsSync(mediaPath(ctx, hash));
}

/** Best-effort mime for a stored blob, from any attachment row referencing it. */
export function mimeFor(ctx: UserContext, hash: string): string {
  const row = ctx.db.prepare(`SELECT mime FROM attachment WHERE sha256 = ? LIMIT 1`).get(hash) as
    | { mime: string }
    | undefined;
  return row?.mime ?? "application/octet-stream";
}
