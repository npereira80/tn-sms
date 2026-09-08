//
//  KeychainStore.swift
//  SMS TN
//
//  Secrets in the macOS Keychain: the sync server's bearer token and the
//  BlueBubbles password. Never written to plaintext files or UserDefaults
//  (spec §3.4).
//
//  Lived under GMessages/ while the app spoke the Google web protocol, which
//  was misleading: nothing here was ever specific to it.
//

import Foundation
import Security

nonisolated enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain error (\(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }
}

nonisolated struct KeychainStore: Sendable {
    /// Bearer token issued by the self-hosted SMS Sync server.
    static let serverToken = KeychainStore(service: "macDroid.SMS-TN", account: "server-token")
    /// BlueBubbles server password (Mac unified inbox / iMessage).
    static let bbPassword = KeychainStore(service: "macDroid.SMS-TN", account: "bb-password")

    let service: String
    let account: String

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func write(_ value: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
