//
//  BlueBubblesClient.swift
//  SMS TN
//
//  Mac unified inbox (v1: receive + display). iMessage lives on the user's
//  BlueBubbles server (not the SMS-sync server), so this is a thin REST client
//  for it. No Socket.IO dependency — we poll `message/query` for new messages,
//  which is enough to display iMessage merged with SMS. Sending iMessage from
//  the Mac is a later pass.
//
//  BlueBubbles REST auth is a `?password=` query param. Endpoints used:
//    POST /api/v1/chat/query      → list chats (+ participants, last message)
//    POST /api/v1/message/query   → messages (filter by chat guid, `after`)
//

import Foundation

// MARK: - Config

/// BlueBubbles connection settings. URL in UserDefaults; password in Keychain.
nonisolated enum BBConfig {
    private static let urlKey = "bbServerURL"

    static var serverURL: URL? {
        get {
            guard let s = UserDefaults.standard.string(forKey: urlKey),
                  !s.isEmpty, let u = URL(string: s) else { return nil }
            return u
        }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: urlKey) }
    }

    static var password: String? {
        get { (try? KeychainStore.bbPassword.read()) ?? nil }
        set {
            if let v = newValue, !v.isEmpty { try? KeychainStore.bbPassword.write(v) }
            else { try? KeychainStore.bbPassword.delete() }
        }
    }

    static var isConfigured: Bool { serverURL != nil && (password?.isEmpty == false) }
}

// MARK: - Wire models (subset of the BlueBubbles API)

nonisolated struct BBHandle: Codable, Sendable {
    let address: String?
}

nonisolated struct BBChat: Codable, Sendable {
    let guid: String
    let chatIdentifier: String?
    let displayName: String?
    let isArchived: Bool?
    let style: Int?                 // 43 = group, 45 = 1:1 (Apple chat style)
    let participants: [BBHandle]?
}

nonisolated struct BBMessage: Codable, Sendable {
    let guid: String
    let text: String?
    let dateCreated: Int64?         // epoch ms
    let isFromMe: Bool?
    let handle: BBHandle?           // sender (nil for from-me)
}

private struct BBChatQueryResponse: Codable { let data: [BBChat]? }
private struct BBMessageQueryResponse: Codable { let data: [BBMessage]? }

/// Normalizes an iMessage handle to the same conversation key the SMS side uses,
/// so a contact's iMessage and SMS threads merge into one row. Phone numbers →
/// leading "+" (if present) plus digits; emails / alphanumeric handles verbatim.
nonisolated enum BBAddress {
    static func normalize(_ addr: String) -> String {
        let t = addr.trimmingCharacters(in: .whitespaces)
        if t.contains("@") || t.rangeOfCharacter(from: .letters) != nil { return t }
        let plus = t.hasPrefix("+") ? "+" : ""
        return plus + t.filter { $0.isNumber }
    }
}

// MARK: - Client

nonisolated final class BlueBubblesClient: @unchecked Sendable {
    private let session = URLSession(configuration: .default)
    private let base: URL
    private let password: String

    init?(config: (url: URL, password: String)? = nil) {
        guard let url = config?.url ?? BBConfig.serverURL,
              let pw = config?.password ?? BBConfig.password, !pw.isEmpty else { return nil }
        base = url
        password = pw
    }

    private func endpoint(_ path: String) -> URL {
        var comps = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "password", value: password)]
        return comps.url!
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type) async throws -> T {
        var req = URLRequest(url: endpoint(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw ServerError.http(code) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Reachability + auth check (also handy for the settings screen).
    func ping() async -> Bool {
        (try? await chats(limit: 1)) != nil
    }

    /// List chats with participants + last message, newest first.
    func chats(limit: Int = 1000) async throws -> [BBChat] {
        let resp = try await post("api/v1/chat/query", body: [
            "limit": limit, "offset": 0,
            "with": ["participants", "lastMessage"],
            "sort": "lastmessage",
        ], as: BBChatQueryResponse.self)
        return resp.data ?? []
    }

    /// Messages for a chat newer than `afterMs` (0 = recent history), oldest first.
    func messages(chatGuid: String, afterMs: Int64, limit: Int = 200) async throws -> [BBMessage] {
        var body: [String: Any] = [
            "chatGuid": chatGuid,
            "limit": limit,
            "with": ["handle"],
            "sort": "DESC",
        ]
        if afterMs > 0 { body["after"] = afterMs }
        let resp = try await post("api/v1/message/query", body: body, as: BBMessageQueryResponse.self)
        return (resp.data ?? []).sorted { ($0.dateCreated ?? 0) < ($1.dateCreated ?? 0) }
    }
}
