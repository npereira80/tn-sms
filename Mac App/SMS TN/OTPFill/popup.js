// Toolbar popover for Bubbles OTP Fill.
//
// Flow: on open, ask the containing macOS app (via the native handler) for the
// freshest unexpired code. If there is one, show it with Fill / Copy. "Fill"
// injects a self-contained function into the active tab that locates an
// OTP-style field only and sets its value, dispatching input/change so page
// validation fires. Nothing is stored here; the app expires codes after 3 min.

const api = (typeof browser !== "undefined") ? browser : chrome;
const NATIVE_APP_ID = "macDroid.SMS-TN.OTPFill";

const els = {
  loading: document.getElementById("loading"),
  hasCode: document.getElementById("has-code"),
  noCode: document.getElementById("no-code"),
  code: document.getElementById("code"),
  sender: document.getElementById("sender"),
  fill: document.getElementById("fill"),
  copy: document.getElementById("copy"),
  status: document.getElementById("status"),
};

let currentCode = null;

function show(state) {
  els.loading.classList.add("hidden");
  els.hasCode.classList.add("hidden");
  els.noCode.classList.add("hidden");
  state.classList.remove("hidden");
}

function setStatus(text, kind) {
  els.status.textContent = text || "";
  els.status.className = "status" + (kind ? " " + kind : "");
}

async function loadCode() {
  let resp = {};
  try {
    resp = await api.runtime.sendNativeMessage(NATIVE_APP_ID, { action: "getCode" });
  } catch (e) {
    resp = {};
  }
  const code = resp && resp.code ? String(resp.code) : "";
  if (!code) {
    show(els.noCode);
    return;
  }
  currentCode = code;
  els.code.textContent = code;
  els.sender.textContent = resp.sender ? `from ${resp.sender}` : "";
  show(els.hasCode);
}

async function fillActiveTab() {
  if (!currentCode) return;
  setStatus("");
  els.fill.disabled = true;
  try {
    const [tab] = await api.tabs.query({ active: true, currentWindow: true });
    if (!tab || !tab.id) throw new Error("no-tab");
    // Ensure the shared matcher is present (content script may not run on every
    // page), then force-fill with the looser threshold.
    await api.scripting.executeScript({
      target: { tabId: tab.id, allFrames: true },
      files: ["otp-fill.js"],
    });
    const results = await api.scripting.executeScript({
      target: { tabId: tab.id, allFrames: true },
      func: (c) => (window.__otpFill ? window.__otpFill.run(c, { strict: false }) : "nofield"),
      args: [currentCode],
    });
    const filled = Array.isArray(results) && results.some((r) => r && r.result === "filled");
    if (filled) {
      setStatus("Filled ✓", "ok");
      setTimeout(() => window.close(), 500);
    } else {
      setStatus("No code field found on this page.", "error");
      els.fill.disabled = false;
    }
  } catch (e) {
    setStatus("Couldn't fill on this page.", "error");
    els.fill.disabled = false;
  }
}

async function copyCode() {
  if (!currentCode) return;
  try {
    await navigator.clipboard.writeText(currentCode);
    setStatus("Copied ✓", "ok");
  } catch (e) {
    setStatus("Copy failed.", "error");
  }
}

els.fill.addEventListener("click", fillActiveTab);
els.copy.addEventListener("click", copyCode);
document.addEventListener("DOMContentLoaded", loadCode);
if (document.readyState !== "loading") loadCode();
