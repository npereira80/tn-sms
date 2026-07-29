//
//  BridgeClient.swift
//  SMS TN
//
//  Swift async wrapper around the Gmbridge xcframework (Go libgm).
//  All bridge calls are blocking network operations, so they are
//  dispatched to a background queue and exposed as async functions.
//  Events arrive on Go-managed threads and are republished as an
//  AsyncStream of GMEvent.
//

import Foundation
import Gmbridge

nonisolated enum BridgeError: LocalizedError {
    case notInitialized
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "Protocol client is not initialized."
        case .emptyResponse: return "The protocol layer returned an empty response."
        }
    }
}

/// Receives Go-side events (on arbitrary Go-managed threads) and
/// forwards them into an AsyncStream.
private nonisolated final class EventSinkAdapter: NSObject, GmbridgeEventSinkProtocol, @unchecked Sendable {
    let continuation: AsyncStream<GMEvent>.Continuation

    init(continuation: AsyncStream<GMEvent>.Continuation) {
        self.continuation = continuation
    }

    func onEvent(_ eventType: String?, payloadJSON: String?) {
        let event = GMEvent.decode(type: eventType ?? "", payloadJSON: payloadJSON ?? "{}")
        continuation.yield(event)
    }
}

nonisolated final class BridgeClient: @unchecked Sendable {
    let events: AsyncStream<GMEvent>

    private let client: GmbridgeClient
    private let sink: EventSinkAdapter
    private let queue = DispatchQueue(label: "gmbridge.calls", qos: .userInitiated)

    init() throws {
        var continuation: AsyncStream<GMEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        sink = EventSinkAdapter(continuation: continuation)
        guard let client = GmbridgeNewClient(sink) else {
            throw BridgeError.notInitialized
        }
        self.client = client
        #if DEBUG
        client.setLogLevel("debug")
        #else
        client.setLogLevel("info")
        #endif
    }

    /// Runs a blocking bridge call on the background queue.
    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let queue = self.queue
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Session lifecycle

    /// sessionJSON: persisted session from the Keychain, or nil for a
    /// fresh (pre-pairing) client.
    func configure(sessionJSON: String?) async throws {
        let client = self.client
        try await run { try client.configure(sessionJSON ?? "") }
    }

    var isLoggedIn: Bool { client.isLoggedIn() }
    var isConnected: Bool { client.isConnected() }

    func sessionJSON() async throws -> String {
        let client = self.client
        let data = try await run { try client.sessionJSON() }
        return String(decoding: data, as: UTF8.self)
    }

    /// Returns the QR payload URL to render. Expires after ~30s.
    func startQRLogin() async throws -> String {
        let client = self.client
        let data = try await run { try client.startQRLogin() }
        return String(decoding: data, as: UTF8.self)
    }

    func refreshQR() async throws -> String {
        let client = self.client
        let data = try await run { try client.refreshQR() }
        return String(decoding: data, as: UTF8.self)
    }

    /// Google-account (Gaia) pairing. cookies is the harvested Google
    /// cookie set. Returns once config fetch succeeds; the emoji and
    /// pair result arrive as events.
    func startGoogleLogin(cookies: [String: String]) async throws {
        let client = self.client
        let data = try JSONSerialization.data(withJSONObject: cookies)
        let json = String(decoding: data, as: UTF8.self)
        try await run { try client.startGoogleLogin(json) }
    }

    func connect() async throws {
        let client = self.client
        try await run { try client.connect() }
    }

    func disconnect() async {
        let client = self.client
        try? await run { client.disconnect() }
    }

    func unpair() async throws {
        let client = self.client
        try await run { try client.unpair() }
    }

    // MARK: - Data

    func listConversations(count: Int = 200, folder: Int = 1) async throws -> [PJConversation] {
        let client = self.client
        let json = try await run { try client.listConversations(count, folder: folder) }
        let resp = try PJ.decode(PJListConversationsResponse.self, from: json)
        return resp.conversations ?? []
    }

    func getConversation(id: String) async throws -> PJConversation {
        let client = self.client
        let json = try await run { try client.getConversation(id) }
        return try PJ.decode(PJConversation.self, from: json)
    }

    /// Gets or creates a conversation for the given phone numbers.
    func startConversation(numbers: [String]) async throws -> PJConversation {
        let client = self.client
        let data = try JSONSerialization.data(withJSONObject: numbers)
        let numbersJSON = String(decoding: data, as: UTF8.self)
        let json = try await run { try client.startConversation(numbersJSON) }
        return try PJ.decode(PJConversation.self, from: json)
    }

    func listMessages(conversationID: String,
                      count: Int = 50,
                      cursor: PJCursor? = nil) async throws -> PJListMessagesResponse {
        let client = self.client
        let cursorID = cursor?.lastItemID ?? ""
        let cursorTS = cursor?.lastItemTimestamp?.value ?? 0
        let json = try await run {
            try client.listMessages(conversationID, count: count,
                                    cursorLastItemID: cursorID, cursorTimestamp: cursorTS)
        }
        return try PJ.decode(PJListMessagesResponse.self, from: json)
    }

    // MARK: - Send

    func sendText(conversationID: String,
                  participantID: String,
                  text: String,
                  forceRCS: Bool) async throws -> PJSendResult {
        let client = self.client
        let json = try await run {
            try client.sendTextMessage(conversationID, participantID: participantID,
                                       text: text, forceRCS: forceRCS)
        }
        return try PJ.decode(PJSendResult.self, from: json)
    }

    /// Uploads attachment bytes; returns opaque protojson MediaContent.
    func uploadMedia(data: Data, fileName: String, mimeType: String) async throws -> String {
        let client = self.client
        let result = try await run {
            try client.uploadMedia(data, fileName: fileName, mimeType: mimeType)
        }
        return String(decoding: result, as: UTF8.self)
    }

    func sendMedia(conversationID: String,
                   participantID: String,
                   mediaContentJSON: String,
                   caption: String,
                   forceRCS: Bool) async throws -> PJSendResult {
        let client = self.client
        let json = try await run {
            try client.sendMediaMessage(conversationID, participantID: participantID,
                                        mediaContentJSON: mediaContentJSON,
                                        caption: caption, forceRCS: forceRCS)
        }
        return try PJ.decode(PJSendResult.self, from: json)
    }

    // MARK: - Media download

    func downloadMedia(mediaID: String, keyBase64: String) async throws -> Data {
        let client = self.client
        return try await run {
            try client.downloadMedia(mediaID, keyBase64: keyBase64)
        }
    }

    func participantThumbnail(participantID: String) async throws -> Data? {
        let client = self.client
        let json = try await run { try client.getParticipantThumbnail(participantID) }
        let resp = try PJ.decode(PJThumbnailResponse.self, from: json)
        guard let b64 = resp.thumbnail?.first?.data?.imageBuffer else { return nil }
        return Data(base64Encoded: b64)
    }

    // MARK: - Conversation actions

    func markRead(conversationID: String, messageID: String) async throws {
        let client = self.client
        try await run { try client.markRead(conversationID, messageID: messageID) }
    }

    func setTyping(conversationID: String) async throws {
        let client = self.client
        try await run { try client.setTyping(conversationID) }
    }

    func sendReaction(messageID: String, emoji: String, add: Bool) async throws {
        let client = self.client
        let action = Int(add ? GmbridgeReactionActionAdd : GmbridgeReactionActionRemove)
        try await run { try client.sendReaction(messageID, emoji: emoji, action: action) }
    }

    func deleteMessage(messageID: String) async throws {
        let client = self.client
        try await run { try client.deleteMessage(messageID) }
    }
}
