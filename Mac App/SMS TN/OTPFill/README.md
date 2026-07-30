# OTPFill — Safari Web Extension (SMS TN)

One-click fill of SMS one-time codes into Safari. When a code arrives, SMS TN
detects it (`OTPCenter`) and publishes the freshest unexpired code to a shared
App Group. This extension's toolbar popover reads it and fills an OTP field on
the active page. Nothing is stored in the browser; codes expire after 3 minutes.

## How it fits together

```
Incoming SMS ─► OTPCenter (app) ─► App Group (group.macDroid.SMS-TN)
                                        │  latestOTP = {code, sender, ts}
                                        ▼
Safari toolbar click ─► popup.js ─► sendNativeMessage
                                        ▼
                          SafariWebExtensionHandler (reads App Group,
                          re-checks 3-min lifetime) ─► {code, sender}
                                        ▼
                          popup "Fill" ─► scripting.executeScript
                                        ▼
                          fills an OTP-only field, dispatches input/change
```

- **Fill UX:** automatic. A content script fills a strong OTP field as soon as a
  code is available (and the field is empty), filling each code once. The
  toolbar popover's **Fill on this page** button is a manual force/retry with
  looser matching (it can overwrite and use the focused field).
- **Field scope:** OTP-style fields (`autocomplete="one-time-code"`, numeric
  single-char groups, name/id/aria/placeholder/label/nearby-text hints like otp,
  code, código, pin, token, sms, verificação). Auto-fill requires a strong match
  and never overwrites a field you've typed in; password inputs qualify only
  with an OTP signal.
- **Permissions:** `scripting` + `nativeMessaging`, plus host access
  (`http/https`) for the content script that does the automatic fill. Safari
  will ask you to allow the extension **on every website** — this is required
  for auto-fill. `activeTab` covers the manual button.

## How the pieces talk

- `background.js` (service worker) relays `otp-getcode` messages from the content
  script to the native handler (content scripts can't call native directly).
- `content.js` detects a strong OTP field, asks the app for the current code, and
  fills it — polling briefly so a code that arrives *after* the page loads still
  lands, and watching for fields added dynamically.
- `otp-fill.js` is the shared matcher/filler used by both the content script
  (strict/auto) and the popup (loose/manual force).

## Files

- `OTPFill/` — synchronized group (auto-included in the target)
  - `SafariWebExtensionHandler.swift` — native bridge; returns the current code.
  - `manifest.json`, `popup.html`, `popup.css`, `popup.js`, `icon-*.png` — the extension.
- `OTPFill Supporting/` — `Info.plist` (NSExtension) and `OTPFill.entitlements`
  (sandbox + App Group), referenced via build settings.

## Build

The target is already wired into `SMS TN.xcodeproj` (target **OTPFill**,
bundle id `macDroid.SMS-TN.OTPFill`, App Group `group.macDroid.SMS-TN`, team
`HDYX3W9SZJ`). Just:

1. Open `SMS TN.xcodeproj` in Xcode. Confirm two targets appear: **SMS TN** and
   **OTPFill**, and that OTPFill is embedded (SMS TN target ▸ Build Phases ▸
   *Embed Foundation Extensions* lists `OTPFill.appex`).
2. Select the **SMS TN** scheme and build/run. The extension is built and
   embedded automatically.
3. If automatic signing prompts about the App Group capability, let Xcode
   register it for both targets (both already have `REGISTER_APP_GROUPS = YES`).

## Enable in Safari

1. Run SMS TN once so the app (and its embedded extension) is registered.
2. Safari ▸ Settings ▸ **Extensions** ▸ enable **SMS TN OTP Fill**.
   - If it doesn't appear: Safari ▸ Settings ▸ Advanced ▸ "Show features for web
     developers", then Develop menu ▸ **Allow Unsigned Extensions** (only needed
     for local debug builds; a Developer ID signed + notarized build is trusted).
3. Pin the extension so its toolbar icon is visible.

## Test

1. Send yourself an SMS with a code (e.g. "Your code is 123456").
2. SMS TN detects it (you'll see the existing notification).
3. On a page with a verification-code field, click the OTPFill toolbar icon.
   The popover shows `123456`; click **Fill**.
4. After 3 minutes the popover shows "No recent code".

## Notes / limits

- The app must be running for a code to be available (it's the source).
- Safari requires the containing app to be launched at least once before the
  extension shows up in Settings.
- Chrome version is planned next; the page-detection/fill logic in `popup.js`
  (`fillOtpField`) is written to be reused there via a native messaging host.
