//
//  SafariWebExtensionHandler.swift
//  OTPFill (Safari Web Extension for SMS TN)
//
//  Native bridge for the toolbar popover. The popup asks for the current
//  one-time code via browser.runtime.sendNativeMessage; we read it from the
//  App Group container the main app writes to, enforce the 3-minute lifetime
//  here too (defence in depth), and return only an unexpired code. Nothing is
//  stored, logged, or mutated by the extension.
//

import SafariServices
import os.log

private let appGroupID = "group.macDroid.SMS-TN"
private let otpKey = "latestOTP"
private let codeLifetime: TimeInterval = 180

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        // We don't need to inspect the request payload: there is only one query
        // ("give me the current code"). Always answer with the freshest code.
        let payload = Self.currentCodePayload()

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// Reads the latest code from the shared App Group and returns it only if it
    /// exists and is still within its lifetime. Returns `{"code": ""}` otherwise.
    static func currentCodePayload() -> [String: Any] {
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
        var out: [String: Any] = ["code": code]
        if let sender = obj["sender"] as? String, !sender.isEmpty { out["sender"] = sender }
        return out
    }
}
