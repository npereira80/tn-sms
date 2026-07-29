import { db } from "./db.js";
import { hub } from "./hub.js";
import { now, sha256 } from "./util.js";
import { nanoid } from "nanoid";

export interface DeviceRow {
  id: string;
  label: string;
  platform: string;
  sim_present: number;
  sim_key: string | null;
  is_primary: number;
  auth_token_hash: string;
  last_seen: number;
}

export function registerDevice(label: string, platform: string): { id: string; token: string } {
  const id = nanoid();
  const token = nanoid(40);
  db.prepare(
    `INSERT INTO device (id, label, platform, auth_token_hash, last_seen)
     VALUES (?, ?, ?, ?, ?)`,
  ).run(id, label, platform, sha256(token), now());
  return { id, token };
}

export function deviceByToken(token: string): DeviceRow | undefined {
  return db
    .prepare(`SELECT * FROM device WHERE auth_token_hash = ?`)
    .get(sha256(token)) as DeviceRow | undefined;
}

export function touch(deviceId: string) {
  db.prepare(`UPDATE device SET last_seen = ? WHERE id = ?`).run(now(), deviceId);
}

/**
 * Record a device's SIM state and re-elect the primary. The primary is the
 * device most-recently reporting the active SIM present. On a SIM swap the
 * new holder becomes primary and the old one is demoted; clients and agents
 * are notified so the send queue re-targets.
 */
export function reportSim(deviceId: string, simPresent: boolean, simKey: string | null) {
  db.prepare(`UPDATE device SET sim_present = ?, sim_key = ?, last_seen = ? WHERE id = ?`)
    .run(simPresent ? 1 : 0, simKey, now(), deviceId);
  electPrimary();
}

export function electPrimary(): DeviceRow | undefined {
  const candidate = db
    .prepare(
      `SELECT * FROM device
       WHERE platform = 'android' AND sim_present = 1
       ORDER BY last_seen DESC LIMIT 1`,
    )
    .get() as DeviceRow | undefined;

  const current = db
    .prepare(`SELECT * FROM device WHERE is_primary = 1`)
    .get() as DeviceRow | undefined;

  if (candidate?.id === current?.id) return current;

  db.prepare(`UPDATE device SET is_primary = 0`).run();
  if (candidate) {
    db.prepare(`UPDATE device SET is_primary = 1 WHERE id = ?`).run(candidate.id);
  }
  hub.broadcast({ type: "primary_changed", deviceId: candidate?.id ?? null, simKey: candidate?.sim_key ?? null });
  return candidate;
}

export function currentPrimary(): DeviceRow | undefined {
  return db.prepare(`SELECT * FROM device WHERE is_primary = 1`).get() as DeviceRow | undefined;
}
