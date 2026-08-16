import type { UserContext } from "./users.js";

/**
 * Compact read API for very constrained watch clients (Garmin Connect IQ).
 *
 * Connect IQ fails somewhere around 32-44KB of JSON depending on the device, and
 * parsing costs more than twice the payload in memory, so these endpoints are
 * shaped for smallness rather than readability:
 *   - single-letter keys
 *   - hard caps on how much comes back
 *   - snippets/bodies truncated
 *   - no attachments, hashes, status or device ids
 *
 * The richer /delta stays as-is for the Mac, Android and Wear OS clients.
 */

const MAX_CHATS = 30;
const MAX_MESSAGES = 40;
const SNIPPET_LEN = 48;
const BODY_LEN = 160;

function clamp(value: unknown, fallback: number, max: number): number {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.min(Math.floor(n), max);
}

function trim(text: string, len: number): string {
  const t = (text ?? "").replace(/\s+/g, " ").trim();
  return t.length <= len ? t : t.slice(0, len - 1) + "…";
}

/**
 * Recent conversations, newest first.
 * Shape: { c: [ { i: id, a: address, s: snippet, t: ts, u: unread(0|1) } ] }
 */
export function watchChats(ctx: UserContext, limitRaw?: unknown) {
  const limit = clamp(limitRaw, 20, MAX_CHATS);
  const rows = ctx.db
    .prepare(
      `SELECT id, address, snippet, last_ts, unread
         FROM conversation
        WHERE id <> ''
        ORDER BY last_ts DESC
        LIMIT ?`,
    )
    .all(limit) as {
      id: string; address: string; snippet: string; last_ts: number; unread: number;
    }[];

  return {
    c: rows.map((r) => ({
      i: r.id,
      a: r.address || r.id,
      s: trim(r.snippet ?? "", SNIPPET_LEN),
      t: r.last_ts ?? 0,
      u: r.unread ? 1 : 0,
    })),
  };
}

/**
 * Newest messages in one conversation, oldest-first so a watch can render them
 * top-to-bottom without sorting.
 * Shape: { m: [ { i: id, d: 0|1 (1 = from me), b: body, t: ts, p: 1 if photo } ] }
 */
export function watchMessages(ctx: UserContext, conversationId: string, limitRaw?: unknown) {
  const limit = clamp(limitRaw, 20, MAX_MESSAGES);
  if (!conversationId) return { m: [] };

  const rows = ctx.db
    .prepare(
      `SELECT m.id, m.direction, m.body, m.ts,
              (SELECT COUNT(*) FROM attachment a WHERE a.message_id = m.id) AS atts
         FROM message m
        WHERE m.conversation_id = ?
        ORDER BY m.ts DESC
        LIMIT ?`,
    )
    .all(conversationId, limit) as {
      id: string; direction: string; body: string; ts: number; atts: number;
    }[];

  return {
    m: rows
      .reverse()
      .map((r) => ({
        i: r.id,
        d: r.direction === "out" ? 1 : 0,
        b: trim(r.body ?? "", BODY_LEN),
        t: r.ts ?? 0,
        ...(r.atts > 0 ? { p: 1 } : {}),
      })),
  };
}
