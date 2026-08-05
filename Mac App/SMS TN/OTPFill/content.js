// Automatic fill. Runs on every page (otp-fill.js is loaded just before this).
// When a strong OTP field is present, it asks the app for the current code and
// fills it. After a successful auto-fill it tells the app the code was consumed,
// so the same (now stale) code is never re-offered to auto-fill — the popup's
// manual button can still force it until a newer code arrives.

(function () {
  const api = (typeof browser !== "undefined") ? browser : chrome;
  const filled = new Set();   // codes already auto-filled on this page
  let lastFilled = null;      // most recent auto-filled code (replaceable)
  let pollTimer = null;
  let pollUntil = 0;

  async function getCode() {
    try {
      // mode:"auto" — the app withholds a code that was already auto-filled.
      const r = await api.runtime.sendMessage({ type: "otp-getcode", mode: "auto" });
      return r && r.code ? String(r.code) : "";
    } catch (e) {
      return "";
    }
  }

  async function markConsumed(code) {
    try {
      await api.runtime.sendMessage({ type: "otp-consumed", code });
    } catch (e) {
      // Non-fatal: worst case the code stays offered until it expires.
    }
  }

  async function attempt() {
    if (!window.__otpFill || !window.__otpFill.qualifies(true)) return false;
    const code = await getCode();
    if (!code || filled.has(code)) return false;
    // `replaceable` lets a NEW code overwrite the previous auto-filled value,
    // which would otherwise be protected by the never-overwrite rule.
    const res = window.__otpFill.run(code, { strict: true, replaceable: lastFilled });
    if (res === "filled") {
      filled.add(code);
      lastFilled = code;
      markConsumed(code);
      return true;
    }
    return false;
  }

  function startPolling() {
    pollUntil = Date.now() + 120000; // watch for up to 2 minutes
    if (pollTimer) return;
    pollTimer = setInterval(async () => {
      if (Date.now() > pollUntil) { clearInterval(pollTimer); pollTimer = null; return; }
      // Keep polling after a fill: a second code may still arrive for this form.
      await attempt();
    }, 1500);
  }

  function kick() {
    if (window.__otpFill && window.__otpFill.qualifies(true)) {
      attempt();
      startPolling();
    }
  }

  let debounce = null;
  function kickDebounced() {
    if (debounce) return;
    debounce = setTimeout(() => { debounce = null; kick(); }, 500);
  }

  // Initial pass + watch for OTP fields that appear later (SPA / dynamic steps).
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", kick);
  } else {
    kick();
  }
  const mo = new MutationObserver(kickDebounced);
  mo.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["type", "autocomplete", "maxlength", "name", "id", "inputmode"],
  });
})();
