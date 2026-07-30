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

  // Keyword signals (English + Portuguese), diacritic-insensitive.
  const KEYWORDS = [
    "one-time-code", "onetimecode", "one time code", "otp", "totp", "mfa", "2fa",
    "verification", "verify", "verificacao", "verificar",
    "code", "codigo", "passcode", "pin", "token", "sms",
    "security code", "securitycode", "sms token", "codigo sms",
    "auth", "authentication", "seguranca", "confirmacao", "confirmar",
  ];
  function norm(s) {
    return (s || "").toString().toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  }
  const KWN = KEYWORDS.map(norm);
  function hasKW(s) { const n = norm(s); return !!n && KWN.some((k) => n.includes(k)); }

  function editable(el) {
    const t = (el.type || "text").toLowerCase();
    return ["text", "tel", "number", "password", ""].includes(t) && !el.disabled && !el.readOnly;
  }
  function labelText(el) {
    let t = "";
    try {
      if (el.id) { const l = document.querySelector(`label[for="${CSS.escape(el.id)}"]`); if (l) t += " " + l.textContent; }
    } catch (e) {}
    const wrap = el.closest && el.closest("label"); if (wrap) t += " " + wrap.textContent;
    const alb = el.getAttribute("aria-labelledby");
    if (alb) alb.split(/\s+/).forEach((id) => { const n = document.getElementById(id); if (n) t += " " + n.textContent; });
    return t;
  }
  function nearbyText(el) {
    let t = "", node = el, hops = 0;
    while (node && hops < 4) {
      let sib = node.previousElementSibling, c = 0;
      while (sib && c < 3) { t += " " + (sib.textContent || ""); sib = sib.previousElementSibling; c++; }
      node = node.parentElement; hops++;
    }
    return t;
  }

  const allInputs = Array.from(document.querySelectorAll("input")).filter(isVisible);

  // 1) Segmented OTP: several single-character numeric boxes. Spread the digits.
  const singles = allInputs.filter((el) =>
    (el.maxLength === 1 || el.getAttribute("maxlength") === "1")
    && (el.inputMode === "numeric" || el.type === "tel" || el.type === "number" || el.type === "text"));
  if (singles.length >= digits.length && singles.length <= 12) {
    for (let i = 0; i < digits.length; i++) setNativeValue(singles[i], digits[i]);
    singles[Math.min(digits.length, singles.length) - 1].focus();
    return true;
  }

  // 2) Score every editable input by how OTP-like it is, then fill the best one.
  const candidates = allInputs.filter(editable);
  let best = null, bestScore = 0;
  for (const el of candidates) {
    const type = (el.type || "text").toLowerCase();
    const ac = norm(el.getAttribute("autocomplete"));
    const attrs = [el.name, el.id, el.className, el.getAttribute("placeholder"),
      el.getAttribute("aria-label"), el.getAttribute("title"), ac].join(" ");
    const lbl = labelText(el);
    const near = nearbyText(el);
    const kwAttr = hasKW(attrs), kwLbl = hasKW(lbl), kwNear = hasKW(near);

    let score = 0;
    if (ac.includes("one-time-code")) score += 100;
    if (norm(el.inputMode) === "numeric") score += 25;
    if (type === "tel" || type === "number") score += 15;
    const ml = parseInt(el.getAttribute("maxlength"), 10);
    if (ml >= 4 && ml <= 8) score += 25;
    if (ml === digits.length) score += 15;
    if (kwAttr) score += 60;
    if (kwLbl) score += 60;
    if (kwNear) score += 30;
    const pat = el.getAttribute("pattern") || ""; if (/\\d|0-9|\d/.test(pat)) score += 15;

    // A password field only qualifies if it carries an OTP signal (banks mask
    // the code), so we never drop the code into a login password box.
    if (type === "password" && !(ac.includes("one-time-code") || kwAttr || kwLbl || kwNear)) score = 0;

    if (score > bestScore) { bestScore = score; best = el; }
  }
  if (best && bestScore >= 40) { setNativeValue(best, digits); best.focus(); return true; }

  // 3) Dedicated OTP page: if the page clearly talks about a code/SMS and there
  // is exactly one editable field, fill it.
  const pageOtpContext = hasKW((document.body && document.body.innerText || "").slice(0, 8000));
  if (pageOtpContext && candidates.length === 1) {
    setNativeValue(candidates[0], digits); candidates[0].focus(); return true;
  }

  // 4) The focused field, if it is itself OTP-ish.
  const ae = document.activeElement;
  if (ae && ae.tagName === "INPUT" && isVisible(ae) && editable(ae)
      && (norm(ae.getAttribute("autocomplete")).includes("one-time-code")
          || norm(ae.inputMode) === "numeric" || (ae.type || "").toLowerCase() === "tel"
          || hasKW([ae.name, ae.id, ae.className].join(" ")) || hasKW(labelText(ae)))) {
    setNativeValue(ae, digits); return true;
  }
  return false;
}

els.fill.addEventListener("click", fillActiveTab);
els.copy.addEventListener("click", copyCode);
document.addEventListener("DOMContentLoaded", loadCode);
if (document.readyState !== "loading") loadCode();
