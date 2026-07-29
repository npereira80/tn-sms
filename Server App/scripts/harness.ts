/**
 * Smoke test: registers two "phones", ingests + dedups, elects a primary via
 * SIM report, enqueues a send, and confirms the primary agent receives it over
 * WebSocket. Run the server (`npm run dev`) in one terminal, then `npm run harness`.
 */
import WebSocket from "ws";

const BASE = process.env.BASE ?? "http://localhost:8787";
const WS = BASE.replace(/^http/, "ws") + "/stream";
const SECRET = process.env.REGISTRATION_SECRET ?? "change-me-to-a-long-random-string";

async function post(path: string, body: unknown, token?: string) {
  const res = await fetch(BASE + path, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  return res.json();
}

async function main() {
  const phoneA = await post("/devices/register", { secret: SECRET, label: "Pixel A", platform: "android" });
  const phoneB = await post("/devices/register", { secret: SECRET, label: "Pixel B", platform: "android" });
  const mac = await post("/devices/register", { secret: SECRET, label: "Mac mini", platform: "mac" });
  console.log("registered:", { phoneA: phoneA.id, phoneB: phoneB.id, mac: mac.id });

  // Phone A holds the SIM -> becomes primary.
  await post("/devices/heartbeat", { simPresent: true, simKey: "+15551234567" }, phoneA.token);
  await post("/devices/heartbeat", { simPresent: false, simKey: null }, phoneB.token);

  // Same SMS backfilled by both phones -> one accepted, one duplicate.
  const sms = { direction: "in", address: "+15559998888", body: "Your code is 123456", ts: Date.now(), type: "sms" };
  const iA = await post("/ingest", { messages: [sms] }, phoneA.token);
  const iB = await post("/ingest", { messages: [sms] }, phoneB.token);
  console.log("ingest A:", iA, "ingest B (dup expected):", iB);

  // Primary agent (phone A) listens; Mac requests a send; A should receive it.
  const agent = new WebSocket(`${WS}?token=${phoneA.token}`);
  const gotSend = new Promise<any>((resolve) => {
    agent.on("message", (raw) => {
      const m = JSON.parse(raw.toString());
      if (m.type === "send") { agent.send(JSON.stringify({ type: "send_status", requestId: m.requestId, status: "sent" })); resolve(m); }
    });
  });
  await new Promise((r) => agent.on("open", r));

  const sendRes = await post("/send", { to: "+15559998888", body: "Reply from Mac" }, mac.token);
  console.log("send enqueue:", sendRes);
  const received = await gotSend;
  console.log("primary agent received send command:", received);

  const health = await (await fetch(BASE + "/health")).json();
  console.log("health:", health);

  agent.close();
  console.log(iA.accepted === 1 && iB.duplicate === 1 && sendRes.dispatched ? "\nPASS ✅" : "\nCHECK ❌");
  process.exit(0);
}
main().catch((e) => { console.error(e); process.exit(1); });
