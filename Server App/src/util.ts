import crypto from "node:crypto";

export const now = () => Date.now();

export function sha256(input: string | Buffer): string {
  return crypto.createHash("sha256").update(input).digest("hex");
}

/** Normalize a phone number to a comparable key (digits + optional leading +). */
export function normalizeAddress(addr: string): string {
  const trimmed = (addr ?? "").trim();
  // Alphanumeric sender IDs (OTP/banks like "Google", "MIN.SAUDE") and email
  // addresses carry no dialable digits. Stripping non-digits would turn every
  // one of them into "" and collapse all unrelated senders into a single
  // empty-id conversation (which also made read-state for them un-syncable).
  // Keep them verbatim so each sender is its own stable conversation key.
  if (/[a-zA-Z]/.test(trimmed)) return trimmed;
  const plus = trimmed.startsWith("+") ? "+" : "";
  return plus + trimmed.replace(/[^\d]/g, "");
}

/**
 * Cross-device dedup key. Two phones that both backfill the same SMS must
 * collapse to one row. Bodies are trimmed and timestamps bucketed to the
 * nearest 10s to absorb minor clock differences between capture paths.
 */
export function contentHash(p: {
  address: string;
  type: string;
  body: string;
  ts: number;
  direction: string;
}): string {
  const bucket = Math.round(p.ts / 10000);
  return sha256([
    normalizeAddress(p.address),
    p.type,
    p.direction,
    p.body.trim(),
    String(bucket),
  ].join("|"));
}
