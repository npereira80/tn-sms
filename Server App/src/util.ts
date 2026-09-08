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
 * The single form a number is keyed by: full international, no punctuation.
 *
 * [normalizeAddress] preserves whatever format arrived, which means one person
 * has two identities. Texting "916309003" and getting the reply back as
 * "+351916309003" — what the carrier actually does — produced two conversation
 * ids and, worse, two different content hashes for the same message. Since the
 * hash *is* cross-device identity, a delete from one client could not be matched
 * by another.
 *
 * [defaultCc] is the account's own country calling code, taken from the phone
 * number the person verified with. Without it a national number cannot be
 * resolved to an international one, so it is left alone rather than guessed at:
 * a wrong country is worse than an inconsistent key.
 *
 * Alphanumeric senders and emails pass through untouched, as above.
 */
export function canonicalAddress(addr: string, defaultCc?: string | null): string {
  const trimmed = (addr ?? "").trim();
  if (!trimmed) return "";
  if (/[a-zA-Z]/.test(trimmed)) return trimmed;

  const digits = trimmed.replace(/[^\d]/g, "");
  if (!digits) return "";

  // Already international, in either notation.
  if (trimmed.startsWith("+")) return `+${digits}`;
  if (digits.startsWith("00")) return `+${digits.slice(2)}`;

  // Short codes (bank/OTP senders) are not dialable numbers and must never be
  // given a country code — doing so would merge unrelated senders.
  if (digits.length < 7) return digits;

  const cc = (defaultCc ?? "").replace(/[^\d]/g, "");
  if (!cc) return digits;

  // Already carries the country code without a plus, e.g. "351916309003".
  if (digits.startsWith(cc) && digits.length > cc.length + 5) return `+${digits}`;

  return `+${cc}${digits}`;
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
  attachments?: { sha256: string }[];
  /// The account's own country calling code, so a national and an
  /// international spelling of the same number hash identically. Omitted only
  /// by callers that predate it; see [canonicalAddress].
  defaultCc?: string | null;
}): string {
  const bucket = Math.round(p.ts / 10000);
  const parts = [
    canonicalAddress(p.address, p.defaultCc),
    p.type,
    p.direction,
    p.body.trim(),
    String(bucket),
  ];
  // Fold in media identity so two MMS with the same (often empty) text at the
  // same instant stay distinct. Sorted for order-independence. Text SMS carry
  // no attachments, so their hash is unchanged (backward compatible).
  const media = (p.attachments ?? []).map((a) => a.sha256).sort();
  if (media.length) parts.push(media.join(","));
  return sha256(parts.join("|"));
}
