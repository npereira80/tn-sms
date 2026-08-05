//
//  SafariWebExtensionHandler.swift
//  OTPFill (Safari Web Extension for Bubbles)
//
//  Native bridge for the extension. The code itself is published by the app to a
//  shared App Group; this reads it, enforces the 3-minute lifetime again
//  (defence in depth), and returns it.
//
//  Auto-fill vs manual fill:
//  Once a code has been filled automatically it is marked "consumed", so the
//  content script won't keep re-offering the same (now stale) code. The manual
//  "Fill on this page" button still returns it, so you can force it if needed.
//  A newly arrived code clears the marker (see OTPCenter), re-enabling auto-fill.
//

import SafariServices
import os.log

private let appGroupID = "group.macDroid.SMS-TN"
private let otpKey = "latestOTP"
private let consumedKey = "consumedOTP"
private let codeLifetime: TimeInterval = 180

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let action = (message?["action"] as? String) ?? "getCode"

        let payload: [String: Any]
        switch action {
        case "consumed":
            // The content script auto-filled this code: stop offering it to
            // auto-fill so a later code isn't shadowed by this one.
            if let code = message?["code"] as? String, !code.isEmpty {
                Self.markConsumed(code)
            }
            payload = ["ok": true]
        default:
            let isAuto = (message?["mode"] as? String) == "auto"
            payload = Self.currentCodePayload(forAuto: isAuto)
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// Current code, if any. In auto mode a code that was already auto-filled is
    /// withheld; manual mode always returns it.
    static func currentCodePayload(forAuto isAuto: Bool) -> [String: Any] {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let raw = defaults.string(forKey: otpKey),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["code"] as? String, !code.isEmpty,
              let ts = obj["ts"] as? Double
        else {
            return ["code": ""]
        }
        if Date().timeIntervalSince1970 - ts > codeLifetime {
            return ["code": ""]
        }
        if isAuto, defaults.string(forKey: consumedKey) == code {
            return ["code": ""]
        }
        var out: [String: Any] = ["code": code]
        if let sender = obj["sender"] as? String, !sender.isEmpty { out["sender"] = sender }
        return out
    }

    static func markConsumed(_ code: String) {
        UserDefaults(suiteName: appGroupID)?.set(code, forKey: consumedKey)
    }
}
