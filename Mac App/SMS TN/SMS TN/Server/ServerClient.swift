//
//  ServerClient.swift
//  SMS TN
//
//  v3 transport: talks to the self-hosted SMS Sync server instead of Google.
//  REST for registration + history (/delta) + outbound send (/send), and a
//  reconnecting WebSocket (/stream) surfaced as an AsyncStream of events.
//  Replaces the libgm BridgeClient as the app's data source.
//

import Foundation

nonisolated enum ServerError: LocalizedError {
    case notRegistered
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notRegistered: return "Device is not registered with the server."
        case .http(let code): return "Server returned HTTP \(code)."
        }
    }
}

nonisolated final class ServerClient: @unchecked Sendable {

    enum Event: Sendable {
        case connected
        case disconnected
        case message(ServerMessage)
        case sendStatus(requestId: String, status: String)
        case conversationRead(conversationId: String, unread: Bool)
        case messageDeleted(id: String, conversationId: String)
        case conversationDeleted(conversationId: String)
    }

    private let session = URLSession(configuration: .default)
    private let base = ServerConfig.baseURL
    private var token: String?

    private var ws: URLSessionWebSocketTask?
    private var continuation: AsyncStream<Event>.Continuation?
    private var closed = false

    // MARK: - Registration

    /// Loads the stored token for this Mac's account, if there is one.
    ///
    /// There is no anonymous registration any more: the server keeps a database
    /// per family member, so a device belongs to a person or to nobody. Signing
    /// in is [startSignIn] / [completeSignIn].
    func ensureRegistered() async throws {
        guard let existing = try KeychainStore.serverToken.read() else {
            throw ServerError.notRegistered
        }
        token = existing
    }

    var isSignedIn: Bool { token != nil }

    /// Ask the server to send a sign-in code to the devices already on [email]'s
    /// account — normally the person's phone.
    ///
    /// This Mac has no SIM, so it can't prove a number the way a phone does;
    /// requiring the code from a device already signed in means having that
    /// phone to hand. If no device is online the server returns the code itself
    /// rather than locking you out, and that's reported back so the UI can say so.
    func startSignIn(email: String) async throws -> (challengeId: String, code: String?) {
        var req = URLRequest(url: base.appending(path: "auth/start-remote"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "secret": ServerConfig.registrationSecret,
            "email": email,
        ])
        let (data, resp) = try await session.data(for: req)
        try Self.checkOK(resp)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let id = body["challengeId"] as? String else { throw ServerError.notRegistered }
        return (id, body["code"] as? String)
    }

    /// Finish signing in and keep the token for this account.
    func completeSignIn(challengeId: String, code: String) async throws {
        var req = URLRequest(url: base.appending(path: "auth/verify"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "challengeId": challengeId,
            "code": code,
            "label": ServerConfig.deviceLabel,
            "platform": "mac",
        ])
        let (data, resp) = try await session.data(for: req)
        try Self.checkOK(resp)
        let reg = try JSONDecoder().decode(ServerRegisterResponse.self, from: data)
        token = reg.token
        try KeychainStore.serverToken.write(reg.token)
    }

    /// Forget this account on this Mac. The local message copy is left alone.
    func signOut() throws {
        token = nil
        try KeychainStore.serverToken.delete()
    }

    // MARK: - History

    func fetchDelta(since: Int64) async throws -> ServerDeltaResponse {
        guard let token else { throw ServerError.notRegistered }
        var comps = URLComponents(url: base.appending(path: "delta"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "since", value: String(since))]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try Self.checkOK(resp)
        return try JSONDecoder().decode(ServerDeltaResponse.self, from: data)
    }

    // MARK: - MMS media

    /// Download a media blob by its server content hash (GET /media/<sha256>).
    func downloadMedia(sha256: String) async throws -> Data {
        guard let token else { throw ServerError.notRegistered }
        var req = URLRequest(url: base.appending(path: "media/\(sha256)"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try Self.checkOK(resp)
        return data
    }

    // MARK: - Send

    @discardableResult
    func postSend(to: String, body: String) async throws -> String {
        guard let token else { throw ServerError.notRegistered }
        var req = URLRequest(url: base.appending(path: "send"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["to": to, "body": body])
        let (data, resp) = try await session.data(for: req)
        try Self.checkOK(resp)
        return (try? JSONDecoder().decode(ServerSendResponse.self, from: data))?.id ?? ""
    }

    // MARK: - Read state (Mac -> server + clients)

    /// Report a conversation's read-state to the server so the phone and other
    /// clients reflect it. The server keys conversations by normalized address;
    /// passing the conversation id (already the normalized address) is fine.
    func markRead(address: String, unread: Bool = false) async throws {
        guard let token else { throw ServerError.notRegistered }
        var req = URLRequest(url: base.appending(path: "read"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "updates": [["address": address, "unread": unread]]
        ])
        let (_, resp) = try await session.data(for: req)
        try Self.checkOK(resp)
    }

    // MARK: - Delete (Mac -> server + clients; does not touch the phone)

    func deleteMessages(ids: [String]) async throws {
        try await postDelete(["messageIds": ids])
    }

    func deleteConversation(id: String) async throws {
        try await postDelete(["conversationId": id])
    }

    private func postDelete(_ body: [String: Any]) async throws {
        guard let token else { throw ServerError.notRegistered }
        var req = URLRequest(url: base.appending(path: "delete"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await session.data(for: req)
        try Self.checkOK(resp)
    }

    // MARK: - Realtime stream

    /// A single long-lived stream of realtime events. The socket reconnects
    /// itself with a fixed backoff until `close()` (or stream termination).
    func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.closed = false
            self.openSocket()
            continuation.onTermination = { [weak self] _ in self?.close() }
        }
    }

    func close() {
        closed = true
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
    }

    private func openSocket() {
        guard let token, !closed else { return }
        var comps = URLComponents(url: base.appending(path: "stream"), resolvingAgainstBaseURL: false)!
        comps.scheme = (base.scheme == "https") ? "wss" : "ws"
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        let task = session.webSocketTask(with: comps.url!)
        ws = task
        task.resume()
        continuation?.yield(.connected)
        receiveLoop()
    }

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.continuation?.yield(.disconnected)
                self.scheduleReconnect()
            case .success(let message):
                switch message {
                case .string(let text): self.handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "message":
            if let raw = obj["message"],
               let data = try? JSONSerialization.data(withJSONObject: raw),
               let msg = try? JSONDecoder().decode(ServerMessage.self, from: data) {
                continuation?.yield(.message(msg))
            }
        case "send_status":
            if let requestId = obj["requestId"] as? String {
                continuation?.yield(.sendStatus(requestId: requestId,
                                                status: obj["status"] as? String ?? ""))
            }
        case "conversation_read":
            if let convID = obj["conversationId"] as? String {
                continuation?.yield(.conversationRead(conversationId: convID,
                                                      unread: obj["unread"] as? Bool ?? false))
            }
        case "message_deleted":
            if let id = obj["id"] as? String {
                continuation?.yield(.messageDeleted(id: id,
                                                    conversationId: obj["conversationId"] as? String ?? ""))
            }
        case "conversation_deleted":
            if let convID = obj["conversationId"] as? String {
                continuation?.yield(.conversationDeleted(conversationId: convID))
            }
        default:
            break   // welcome / primary_changed: no client action needed
        }
    }

    private func scheduleReconnect() {
        guard !closed else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.closed else { return }
            self.openSocket()
        }
    }

    private static func checkOK(_ resp: URLResponse) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw ServerError.http(code) }
    }
}
