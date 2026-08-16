import type { WebSocket } from "ws";

/**
 * In-memory registry of live WebSocket connections keyed by device id.
 * Used to push realtime events to clients and dispatch send-commands to
 * the primary Android agent.
 *
 * Every connection carries the user it belongs to, because a broadcast must
 * never cross accounts: one family member's incoming message is not an event
 * another's devices should ever see.
 */
class Hub {
  private sockets = new Map<string, Set<WebSocket>>();
  private owner = new Map<string, string>();          // deviceId -> userId

  add(userId: string, deviceId: string, ws: WebSocket) {
    let set = this.sockets.get(deviceId);
    if (!set) this.sockets.set(deviceId, (set = new Set()));
    set.add(ws);
    this.owner.set(deviceId, userId);
    ws.on("close", () => {
      set!.delete(ws);
      if (set!.size === 0) this.owner.delete(deviceId);
    });
  }

  /** Send to every connection of one device. Returns true if delivered. */
  toDevice(deviceId: string, event: unknown): boolean {
    const set = this.sockets.get(deviceId);
    if (!set || set.size === 0) return false;
    const payload = JSON.stringify(event);
    for (const ws of set) safeSend(ws, payload);
    return true;
  }

  /**
   * Fan-out to one user's connected clients (e.g. new inbound message, primary
   * change). `exceptDeviceId` skips the device that triggered the change so it
   * never receives the echo of its own action (it already applied it locally).
   */
  broadcast(userId: string, event: unknown, exceptDeviceId?: string): boolean {
    const payload = JSON.stringify(event);
    let delivered = false;
    for (const [deviceId, set] of this.sockets) {
      if (this.owner.get(deviceId) !== userId) continue;
      if (exceptDeviceId && deviceId === exceptDeviceId) continue;
      for (const ws of set) {
        safeSend(ws, payload);
        delivered = true;
      }
    }
    return delivered;
  }

  isOnline(deviceId: string): boolean {
    const set = this.sockets.get(deviceId);
    return !!set && set.size > 0;
  }
}

function safeSend(ws: WebSocket, payload: string) {
  if (ws.readyState === ws.OPEN) {
    try { ws.send(payload); } catch { /* dropped socket */ }
  }
}

export const hub = new Hub();
