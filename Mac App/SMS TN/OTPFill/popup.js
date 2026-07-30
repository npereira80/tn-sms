// Toolbar popover for SMS TN OTP Fill.
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
    const results = await api.scripting.executeScript({
      target: { tabId: tab.id, allFrames: true },
      func: fillOtpField,
      args: [currentCode],
    });
    const filled = Array.isArray(results) && results.some((r) => r && r.result === true);
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

// ── Injected into the page. Must be fully self-contained (no outer scope). ──
function fillOtpField(code) {
  function isVisible(el) {
    if (!el || el.disabled || el.readOnly) return false;
    const s = window.getComputedStyle(el);
    if (s.display === "none" || s.visibility === "hidden" || s.opacity === "0") return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }
  function setNativeValue(el, value) {
    const proto = el instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype
      : HTMLInputElement.prototype;
    const desc = Object.getOwnPropertyDescriptor(proto, "value");
    if (desc && desc.set) { desc.set.call(el, value); } else { el.value = value; }
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  const digits = String(code).replace(/\D/g, "");
  if (!digits) return false;

  // 1) Segmented OTP: several single-character numeric boxes. Spread the digits.
  const singles = Array.from(document.querySelectorAll("input"))
    .filter((el) => isVisible(el)
      && (el.maxLength === 1 || el.getAttribute("maxlength") === "1")
      && (el.inputMode === "numeric" || el.type === "tel" || el.type === "number" || el.type === "text"));
  if (singles.length >= digits.length && singles.length <= 12) {
    for (let i = 0; i < digits.length; i++) setNativeValue(singles[i], digits[i]);
    singles[Math.min(digits.length, singles.length) - 1].focus();
    return true;
  }

  // 2) A single OTP-style field. Only fields that hint they want a one-time code.
  const selectors = [
    'input[autocomplete="one-time-code"]',
    'input[autocomplete~="one-time-code"]',
    'input[name*="otp" i]', 'input[id*="otp" i]',
    'input[name*="onetime" i]', 'input[id*="onetime" i]',
    'input[name*="verification" i]', 'input[id*="verification" i]',
    'input[name*="verify" i]', 'input[id*="verify" i]',
    'input[name*="passcode" i]', 'input[id*="passcode" i]',
    'input[name*="securitycode" i]', 'input[id*="securitycode" i]',
    'input[name*="code" i]', 'input[id*="code" i]',
    'input[name*="pin" i]', 'input[id*="pin" i]',
    'input[aria-label*="code" i]', 'input[placeholder*="code" i]',
    'input[aria-label*="verification" i]', 'input[placeholder*="verification" i]',
  ];
  for (const sel of selectors) {
    const el = document.querySelector(sel);
    if (el && isVisible(el)) { setNativeValue(el, digits); el.focus(); return true; }
  }

  // 3) The focused field, but only if it is itself OTP-ish (numeric one-liner).
  const ae = document.activeElement;
  if (ae && ae.tagName === "INPUT" && isVisible(ae)
      && (ae.autocomplete === "one-time-code" || ae.inputMode === "numeric" || ae.type === "tel")) {
    setNativeValue(ae, digits);
    return true;
  }
  return false;
}

els.fill.addEventListener("click", fillActiveTab);
els.copy.addEventListener("click", copyCode);
document.addEventListener("DOMContentLoaded", loadCode);
if (document.readyState !== "loading") loadCode();
