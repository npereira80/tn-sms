//
//  OTPCenter.swift
//  SMS TN
//
//  OTP detection per spec §3.3/§3.4: 4-8 digit sequences near keywords
//  (English + Portuguese variants). Codes are kept in memory only,
//  expire after 3 minutes, and are never logged or persisted. This is
//  the source the browser extensions will consume in a later phase.
//

import AppKit
import Foundation
import UserNotifications

nonisolated struct OTPDetection: Sendable, Equatable {
    let code: String
    let sender: String
    let messageSnippet: String
    let detectedAt: Date

    var isExpired: Bool {
        Date().timeIntervalSince(detectedAt) > OTPDetector.codeLifetime
    }
}

nonisolated enum OTPDetector {
    /// Codes offered downstream expire quickly (spec: 2-3 minutes).
    static let codeLifetime: TimeInterval = 180

    // Keyword list: English + common localized variants incl. Portuguese
    // (spec explicitly requires "código", "verificação").
    private static let keywords: [String] = [
        "code", "otp", "verification", "verify", "passcode", "password",
        "2fa", "pin", "token", "auth",
        "código", "codigo", "verificação", "verificacao", "verificar",
        "senha", "confirmação", "confirmacao", "acesso",
    ]

    private static let codeRegex = try! NSRegularExpression(
        pattern: #"(?<!\d)(\d{4,8}|\d{3}[ -]\d{3})(?!\d)"#)

    /// Returns the most likely OTP code in an incoming message, if any.
    static func detect(in text: String) -> String? {
        let lowered = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: Locale(identifier: "en_US"))
        guard keywords.contains(where: { keyword in
            lowered.contains(keyword.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                             locale: Locale(identifier: "en_US")))
        }) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = codeRegex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let raw = String(text[matchRange])
        let digits = raw.filter(\.isNumber)
        // Ignore obvious non-codes (years, short numbers already excluded by regex).
        if digits.count == 4, let year = Int(digits), (1900...2099).contains(year),
           !lowered.contains("code") && !lowered.contains("codigo") && !lowered.contains("código") {
            return nil
        }
        return digits
    }
}

/// In-memory holder for active codes + user notification with copy action.
@MainActor
@Observable
final class OTPCenter {
    private(set) var active: [OTPDetection] = []
    private var expiryTask: Task<Void, Never>?

    static let notificationCategoryID = "OTP_CODE"
    static let copyActionID = "COPY_OTP"

    func registerNotificationCategory() {
        let copy = UNNotificationAction(identifier: Self.copyActionID,
                                        title: "Copy Code",
                                        options: [])
        let category = UNNotificationCategory(identifier: Self.notificationCategoryID,
                                              actions: [copy],
                                              intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func handleIncoming(text: String, sender: String) {
        guard let code = OTPDetector.detect(in: text) else { return }
        let detection = OTPDetection(code: code,
                                     sender: sender,
                                     messageSnippet: String(text.prefix(80)),
                                     detectedAt: Date())
        active.removeAll { $0.code == code || $0.isExpired }
        active.append(detection)
        scheduleExpiry()
        postNotification(for: detection)
    }

    func copyToClipboard(_ detection: OTPDetection) {
        guard !detection.isExpired else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detection.code, forType: .string)
    }

    func copyCode(_ code: String) {
        guard let detection = active.first(where: { $0.code == code && !$0.isExpired }) else { return }
        copyToClipboard(detection)
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(OTPDetector.codeLifetime))
            guard let self, !Task.isCancelled else { return }
            self.active.removeAll(where: \.isExpired)
        }
    }

    private func postNotification(for detection: OTPDetection) {
        let content = UNMutableNotificationContent()
        content.title = "Verification code from \(detection.sender)"
        content.body = "Code \(detection.code) — click Copy Code to use it."
        content.categoryIdentifier = Self.notificationCategoryID
        content.userInfo = ["otpCode": detection.code]
        let request = UNNotificationRequest(identifier: "otp-\(detection.code)-\(detection.detectedAt.timeIntervalSince1970)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
