// Background service worker. Content scripts can't call the native handler
// directly, so they message here and we relay to the containing app via
// native messaging, returning the current unexpired code (or {code:""}).

const api = (typeof browser !== "undefined") ? browser : chrome;
const NATIVE_APP_ID = "macDroid.SMS-TN.OTPFill";

api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "otp-getcode") {
    api.runtime.sendNativeMessage(NATIVE_APP_ID, { action: "getCode" })
      .then((r) => sendResponse(r || {}))
      .catch(() => sendResponse({}));
    return true; // keep the message channel open for the async response
  }
  return false;
});
