// Automatic fill. Runs on every page (otp-fill.js is loaded just before this).
// When a strong OTP field is present and empty, it asks the app (via the
// background worker) for the current code and fills it — once per code. If the
// field appears before the SMS does, it polls briefly so a code that arrives
// after the page loads still lands. The popup's button remains a manual force.

(function () {
  const api = (typeof browser !== "undefined") ? browser : chrome;
  const filled = new Set();           // codes already auto-filled on this page
  let pollTimer = null;
  let pollUntil = 0;

  async function getCode() {
    try {
      const r = await api.runtime.sendMessage({ type: "otp-getcode" });
      return r && r.code ? String(r.code) : "";
    } catch (e) {
      return "";
    }
  }

  async function attempt() {
    if (!window.__otpFill || !window.__otpFill.qualifies(true)) return false;
    const code = await getCode();
    if (!code || filled.has(code)) return false;
    const res = window.__otpFill.run(code, { strict: true });
    if (res === "filled") { filled.add(code); return true; }
    return false;
  }

  function startPolling() {
    pollUntil = Date.now() + 120000; // watch for up to 2 minutes
    if (pollTimer) return;
    pollTimer = setInterval(async () => {
      if (Date.now() > pollUntil) { clearInterval(pollTimer); pollTimer = null; return; }
      const done = await attempt();
      if (done) { clearInterval(pollTimer); pollTimer = null; }
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
