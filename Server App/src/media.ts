import fs from "node:fs";
import path from "node:path";
import { paths } from "./config.js";
import { sha256 } from "./util.js";
import { db } from "./db.js";

/**
 * Content-addressed blob store for MMS media. Files live under data/media/
 * named by their sha256, so identical media shared across messages/devices is
 * stored once. The `attachment` table maps messages to these blobs (+ mime).
 */

const HEX64 = /^[a-f0-9]{64}$/;

/** True if `hash` is a well-formed sha256 hex string (guards path traversal). */
export function isValidHash(hash: string): boolean {
  return HEX64.test(hash);
}

export function mediaPath(hash: string): string {
  return path.join(paths.media(), hash);
}

/** Store bytes, returning the content hash + size. Idempotent (dedup by hash). */
export function storeMedia(buf: Buffer): { sha256: string; size: number } {
  const hash = sha256(buf);
  const p = mediaPath(hash);
  if (!fs.existsSync(p)) fs.writeFileSync(p, buf);
  return { sha256: hash, size: buf.length };
}

export function mediaExists(hash: string): boolean {
  return isValidHash(hash) && fs.existsSync(mediaPath(hash));
}

/** Best-effort mime for a stored blob, from any attachment row referencing it. */
export function mimeFor(hash: string): string {
  const row = db.prepare(`SELECT mime FROM attachment WHERE sha256 = ? LIMIT 1`).get(hash) as
    | { mime: string }
    | undefined;
  return row?.mime ?? "application/octet-stream";
}
