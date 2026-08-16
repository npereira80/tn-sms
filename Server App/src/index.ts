import express, { type Request, type Response, type NextFunction } from "express";
import { createServer } from "node:http";
import { WebSocketServer } from "ws";
import { z } from "zod";
import { config } from "./config.js";
import { hub } from "./hub.js";
import {
  userContext, userForToken, startSignup, verifySignup, pruneSignups, userById,
  type UserContext,
} from "./users.js";
import { migrateLegacyInstall } from "./migrate.js";
import {
  registerDevice, deviceByToken, touch, reportSim, currentPrimary, type DeviceRow,
} from "./devices.js";
import {
  ingest, delta, applyReadUpdates, reconcile, deleteItems, conversationMessageKeys,
} from "./messages.js";
import { enqueueSend, updateSendStatus, redeliverQueued } from "./send.js";
import { storeMedia, mediaExists, mediaPath, mimeFor, isValidHash } from "./media.js";
import { watchChats, watchMessages } from "./watch.js";
import fs from "node:fs";

const app = express();
app.use(express.json({ limit: "10mb" }));

// ---- auth middleware ----------------------------------------------------
// A token identifies both the person and the device. The registry resolves it to
// a user, and everything downstream then works against that user's own database
// — so a handler physically cannot read another account's messages.
interface AuthedRequest extends Request { device?: DeviceRow; ctx?: UserContext }

function auth(req: AuthedRequest, res: Response, next: NextFunction) {
  const token = (req.header("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const owner = token ? userForToken(token) : undefined;
  if (!owner) return res.status(401).json({ error: "unauthorized" });

  const ctx = userContext(owner.userId);
  const device = deviceByToken(ctx, token);
  if (!device) return res.status(401).json({ error: "unauthorized" });

  req.ctx = ctx;
  req.device = device;
  touch(ctx, device.id);
  next();
}

// ---- REST ---------------------------------------------------------------
app.get("/health", (_req, res) => res.json({ ok: true }));

// ---- accounts -----------------------------------------------------------
// The shared secret still gates the whole server, so nobody who merely finds the
// URL can enrol; the email + code below is what separates one family member's
// data from another's.

const signupStartBody = z.object({
  secret: z.string(),
  email: z.string().email(),
  phone: z.string().min(4),
});
app.post("/auth/start", (req, res) => {
  const p = signupStartBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });
  if (p.data.secret !== config.registrationSecret) return res.status(403).json({ error: "bad secret" });

  pruneSignups();
  const { challengeId, code } = startSignup(p.data.email, p.data.phone);
  // The code goes back to the caller because the server has no SIM and cannot
  // send an SMS. The phone texts the code to its own number and reads it back,
  // which proves the SIM is really in that phone and that the number is the one
  // its conversations will be keyed by. It is a check on the client's side, not
  // a secret the server is withholding — see README.
  res.json({ challengeId, code });
});

const signupVerifyBody = z.object({
  challengeId: z.string(),
  code: z.string(),
  label: z.string().default(""),
  platform: z.enum(["android", "mac", "ipad"]).default("android"),
});
app.post("/auth/verify", (req, res) => {
  const p = signupVerifyBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });

  const result = verifySignup(p.data.challengeId, p.data.code);
  if (!result.ok) return res.status(400).json({ error: result.reason });

  const ctx = userContext(result.user.id);
  const device = registerDevice(ctx, p.data.label, p.data.platform);
  res.json({ ...device, userId: result.user.id, email: result.user.email });
});

/** Who this token belongs to — lets a client show the signed-in account. */
app.get("/auth/me", auth, (req: AuthedRequest, res) => {
  const user = userById(req.ctx!.userId);
  res.json({ userId: req.ctx!.userId, email: user?.email ?? null, phone: user?.phone ?? null });
});

const heartbeatBody = z.object({
  simPresent: z.boolean().default(false),
  simKey: z.string().nullable().default(null),
});
app.post("/devices/heartbeat", auth, (req: AuthedRequest, res) => {
  const p = heartbeatBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });
  reportSim(req.ctx!, req.device!.id, p.data.simPresent, p.data.simKey);
  res.json({ ok: true, primary: currentPrimary(req.ctx!)?.id ?? null });
});

const attachmentSchema = z.object({
  sha256: z.string(),
  mime: z.string(),
  size: z.number().optional(),
  name: z.string().optional(),
});
const ingestBody = z.object({
  messages: z.array(z.object({
    direction: z.enum(["in", "out"]),
    address: z.string(),
    body: z.string().default(""),
    ts: z.number(),
    type: z.enum(["sms", "mms"]).default("sms"),
    providerId: z.string().optional(),
    attachments: z.array(attachmentSchema).optional(),
  })),
});
app.post("/ingest", auth, (req: AuthedRequest, res) => {
  const p = ingestBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });
  res.json(ingest(req.ctx!, req.device!.id, p.data.messages));
});

app.get("/delta", auth, (req: AuthedRequest, res) => {
  const since = Number(req.query.since ?? 0);
  res.json(delta(req.ctx!, Number.isFinite(since) ? since : 0));
});

// ---- compact watch API (Garmin Connect IQ) --------------------------------
// Connect IQ caps web responses at roughly 32KB and charges double that in
// memory to parse them, so these return short-key, hard-capped payloads instead
// of /delta. See watch.ts.
app.get("/watch/chats", auth, (req: AuthedRequest, res) => {
  res.json(watchChats(req.ctx!, req.query.limit));
});

app.get("/watch/messages", auth, (req: AuthedRequest, res) => {
  res.json(watchMessages(req.ctx!, String(req.query.conversationId ?? ""), req.query.limit));
});

// Everything this conversation currently holds, so a client can drop local
// copies of messages that were deleted elsewhere. Deletion tombstones are
// incremental and a client that missed one (or stored the message under a
// different id) would otherwise keep showing it forever; this is the positive
// check that always converges.
app.get("/conversation/:id/messages", auth, (req: AuthedRequest, res) => {
  res.json(conversationMessageKeys(req.ctx!, String(req.params.id)));
});

const readBody = z.object({
  updates: z.array(z.object({ address: z.string(), unread: z.boolean() })),
});
app.post("/read", auth, (req: AuthedRequest, res) => {
  const p = readBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });
  applyReadUpdates(req.ctx!, p.data.updates, req.device!.id);
  res.json({ ok: true });
});

// Deletion mirror: body is the phone's current SMS set (same shape as /ingest).
app.post("/reconcile", auth, (req: AuthedRequest, res) => {
  const p = ingestBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });
  res.json(reconcile(req.ctx!, p.data.messages));
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
  res.json(deleteItems(req.ctx!, p.data, req.device!.id));
});

// ---- MMS media relay ------------------------------------------------------
// Upload a media blob (raw binary body). Content-addressed: returns its sha256,
// which the client then references from an /ingest attachment entry.
app.post("/media", auth, express.raw({ type: () => true, limit: "25mb" }), (req: AuthedRequest, res) => {
  const buf = req.body;
  if (!Buffer.isBuffer(buf) || buf.length === 0) return res.status(400).json({ error: "empty body" });
  res.json(storeMedia(req.ctx!, buf));
});

// Download a media blob by content hash (streamed with its stored mime type).
app.get("/media/:hash", auth, (req: AuthedRequest, res) => {
  const hash = String(req.params.hash);
  // Resolved inside the caller's own media directory, so one account can't pull
  // another's blob even knowing its hash.
  if (!isValidHash(hash) || !mediaExists(req.ctx!, hash)) return res.status(404).json({ error: "not found" });
  res.setHeader("Content-Type", mimeFor(req.ctx!, hash));
  res.setHeader("Cache-Control", "private, max-age=31536000, immutable"); // content-addressed = immutable
  fs.createReadStream(mediaPath(req.ctx!, hash)).pipe(res);
});

const sendBody = z.object({
  to: z.string(),
  body: z.string().default(""),
  attachments: z.array(attachmentSchema).optional(),
});
app.post("/send", auth, (req: AuthedRequest, res) => {
  const p = sendBody.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: p.error.message });
  res.json(enqueueSend(req.ctx!, req.device!.id, p.data.to, p.data.body, p.data.attachments ?? []));
});

// ---- WebSocket ----------------------------------------------------------
const server = createServer(app);
const wss = new WebSocketServer({ server, path: "/stream" });

wss.on("connection", (ws, req) => {
  const url = new URL(req.url ?? "", "http://localhost");
  const token = url.searchParams.get("token") ?? "";
  const owner = token ? userForToken(token) : undefined;
  if (!owner) { ws.close(4401, "unauthorized"); return; }
  const ctx = userContext(owner.userId);
  const device = deviceByToken(ctx, token);
  if (!device) { ws.close(4401, "unauthorized"); return; }

  hub.add(ctx.userId, device.id, ws);
  touch(ctx, device.id);
  redeliverQueued(ctx, device.id);
  ws.send(JSON.stringify({ type: "welcome", deviceId: device.id, primary: currentPrimary(ctx)?.id ?? null }));

  ws.on("message", (raw) => {
    let msg: any;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    // Agents report send progress back over the same socket.
    if (msg?.type === "send_status" && typeof msg.requestId === "string") {
      updateSendStatus(ctx, msg.requestId, String(msg.status ?? "sent"));
    }
  });
});

// Adopt a pre-multi-user install before serving anything, so the first request
// already sees a real account rather than an empty one.
migrateLegacyInstall(process.env.OWNER_EMAIL ?? null);

server.listen(config.port, () => {
  const secretMode =
    config.registrationSecret === "change-me-to-a-long-random-string"
      ? "DEFAULT ⚠️  (.env not loaded)"
      : "custom (.env loaded)";
  console.log(`SMS Sync server listening on :${config.port} (data: ${config.dataDir})`);
  console.log(`Registration secret: ${secretMode}`);
});
