// Background service worker. Content scripts can't call the native handler
// directly, so they message here and we relay to the containing app.

const api = (typeof browser !== "undefined") ? browser : chrome;
const NATIVE_APP_ID = "macDroid.SMS-TN.OTPFill";

api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg) return false;

  if (msg.type === "otp-getcode") {
    api.runtime
      .sendNativeMessage(NATIVE_APP_ID, { action: "getCode", mode: msg.mode || "manual" })
      .then((r) => sendResponse(r || {}))
      .catch(() => sendResponse({}));
    return true; // keep the message channel open for the async response
  }

  // Auto-fill happened: stop offering this code to auto-fill.
  if (msg.type === "otp-consumed") {
    api.runtime
      .sendNativeMessage(NATIVE_APP_ID, { action: "consumed", code: msg.code })
      .then(() => sendResponse({ ok: true }))
      .catch(() => sendResponse({ ok: false }));
    return true;
  }

  return false;
});
