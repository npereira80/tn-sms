import { db } from "./db.js";
import { hub } from "./hub.js";
import { currentPrimary } from "./devices.js";
import { now } from "./util.js";
import { nanoid } from "nanoid";

/**
 * Enqueue an outbound message from a Mac/iPad client and dispatch it to the
 * primary Android agent over its WebSocket. If the primary is offline the
 * request stays queued for redelivery on reconnect (see redeliverQueued).
 */
export function enqueueSend(requestedBy: string, to: string, body: string) {
  const id = nanoid();
  const ts = now();
  const primary = currentPrimary();
  db.prepare(
    `INSERT INTO send_request (id, "to", body, requested_by, target_device_id, status, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, 'queued', ?, ?)`,
  ).run(id, to, body, requestedBy, primary?.id ?? null, ts, ts);

  const dispatched =
    !!primary && hub.toDevice(primary.id, { type: "send", requestId: id, to, body });
  return { id, dispatched, primaryDeviceId: primary?.id ?? null };
}

export function updateSendStatus(requestId: string, status: string) {
  db.prepare(`UPDATE send_request SET status = ?, updated_at = ? WHERE id = ?`)
    .run(status, now(), requestId);
  hub.broadcast({ type: "send_status", requestId, status });
}

/** Re-dispatch queued sends to the primary when an agent (re)connects. */
export function redeliverQueued(deviceId: string) {
  const rows = db
    .prepare(`SELECT * FROM send_request WHERE status = 'queued' AND target_device_id = ?`)
    .all(deviceId) as any[];
  for (const r of rows) {
    hub.toDevice(deviceId, { type: "send", requestId: r.id, to: r.to, body: r.body });
  }
  return rows.length;
}
