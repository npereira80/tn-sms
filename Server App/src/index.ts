import express, { type Request, type Response, type NextFunction } from "express";
import { createServer } from "node:http";
import { WebSocketServer } from "ws";
import { z } from "zod";
import { config } from "./config.js";
import "./db.js";
import { hub } from "./hub.js";
import {
  registerDevice, deviceByToken, touch, reportSim, currentPrimary, type DeviceRow,
} from "./devices.js";
import { ingest, delta, applyReadUpdates, reconcile, deleteItems } from "./messages.js";
import { enqueueSend, updateSendStatus, redeliverQueued } from "./send.js";

const app = express();
app.use(express.json({ limit: "10mb" }));

// ---- auth middleware ----------------------------------------------------
interface AuthedRequest extends Request { device?: DeviceRow }

function auth(req: AuthedRequest, res: Response, next: NextFunction) {
  const token = (req.header("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const device = token ? deviceByToken(token) : undefined;
  if (!device) return res.status(401).json({ error: "unauthorized" });
  req.device = device;
  touch(device.id);
  next();
}

// ---- REST ---------------------------------------------------------------
app.get("/health", (_req, res) => res.json({ ok: true, primary: currentPrimary()?.id ?? null }));

const registerBody = z.object({
  secret: z.string(),
  label: z.string().default(""),
  platform: z.enum(["android", "mac", "ipad"]).default("android"),
});
app.post("/devices/register", (req, res) => {
  const p = registerBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });
  if (p.data.secret !== config.registrationSecret) return res.status(403).json({ error: "bad secret" });
  res.json(registerDevice(p.data.label, p.data.platform));
});

const heartbeatBody = z.object({
  simPresent: z.boolean().default(false),
  simKey: z.string().nullable().default(null),
});
app.post("/devices/heartbeat", auth, (req: AuthedRequest, res) => {
  const p = heartbeatBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });
  reportSim(req.device!.id, p.data.simPresent, p.data.simKey);
  res.json({ ok: true, primary: currentPrimary()?.id ?? null });
});

const ingestBody = z.object({
  messages: z.array(z.object({
    direction: z.enum(["in", "out"]),
    address: z.string(),
    body: z.string().default(""),
    ts: z.number(),
    type: z.enum(["sms", "mms"]).default("sms"),
    providerId: z.string().optional(),
  })),
});
app.post("/ingest", auth, (req: AuthedRequest, res) => {
  const p = ingestBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });
  res.json(ingest(req.device!.id, p.data.messages));
});

app.get("/delta", auth, (req, res) => {
  const since = Number(req.query.since ?? 0);
  res.json(delta(Number.isFinite(since) ? since : 0));
});

const readBody = z.object({
  updates: z.array(z.object({ address: z.string(), unread: z.boolean() })),
});
app.post("/read", auth, (req: AuthedRequest, res) => {
  const p = readBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });
  applyReadUpdates(p.data.updates, req.device!.id);
  res.json({ ok: true });
});

// Deletion mirror: body is the phone's current SMS set (same shape as /ingest).
app.post("/reconcile", auth, (req: AuthedRequest, res) => {
  const p = ingestBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });
  res.json(reconcile(p.data.messages));
});

// Client-initiated delete (Mac → server + all synced clients).
const deleteBody = z.object({
  messageIds: z.array(z.string()).optional(),
  messageHashes: z.array(z.string()).optional(),
  conversationId: z.string().optional(),
});
app.post("/delete", auth, (req: AuthedRequest, res) => {
  const p = deleteBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });
  res.json(deleteItems(p.data, req.device!.id));
});

const sendBody = z.object({ to: z.string(), body: z.string() });
app.post("/send", auth, (req: AuthedRequest, res) => {
  const p = sendBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });
  res.json(enqueueSend(req.device!.id, p.data.to, p.data.body));
});

// ---- WebSocket ----------------------------------------------------------
const server = createServer(app);
const wss = new WebSocketServer({ server, path: "/stream" });

wss.on("connection", (ws, req) => {
  const url = new URL(req.url ?? "", "http://localhost");
  const token = url.searchParams.get("token") ?? "";
  const device = deviceByToken(token);
  if (!device) { ws.close(4401, "unauthorized"); return; }

  hub.add(device.id, ws);
  touch(device.id);
  redeliverQueued(device.id);
  ws.send(JSON.stringify({ type: "welcome", deviceId: device.id, primary: currentPrimary()?.id ?? null }));

  ws.on("message", (raw) => {
    let msg: any;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    // Agents report send progress back over the same socket.
    if (msg?.type === "send_status" && typeof msg.requestId === "string") {
      updateSendStatus(msg.requestId, String(msg.status ?? "sent"));
    }
  });
});

server.listen(config.port, () => {
  const secretMode =
    config.registrationSecret === "change-me-to-a-long-random-string"
      ? "DEFAULT ⚠️  (.env not loaded)"
      : "custom (.env loaded)";
  console.log(`SMS Sync server listening on :${config.port} (data: ${config.dataDir})`);
  console.log(`Registration secret: ${secretMode}`);
});
