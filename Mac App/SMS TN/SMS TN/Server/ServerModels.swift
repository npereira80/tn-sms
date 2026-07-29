//
//  ServerModels.swift
//  SMS TN
//
//  Codable wire models matching the SMS Sync server's JSON (see
//  Server App/src). Snake_case keys are mapped explicitly. Unknown keys
//  (provider_id, content_hash, source_device_id, …) are ignored.
//

import Foundation

nonisolated struct ServerMessage: Codable, Sendable {
    let id: String
    let conversationId: String
    let direction: String        // "in" | "out"
    let address: String
    let body: String
    let ts: Int64                // epoch milliseconds
    let type: String             // "sms" | "mms"
    let status: String?
    let updatedAt: Int64?        // server change cursor

    enum CodingKeys: String, CodingKey {
        case id, direction, address, body, ts, type, status
        case conversationId = "conversation_id"
        case updatedAt = "updated_at"
    }
}

nonisolated struct ServerConversationState: Codable, Sendable {
    let id: String
    let unread: Int   // SQLite 0/1
}

/// A deletion tombstone from /delta. `messageId` is the server nanoid the row
/// had (used to delete our local copy, which is keyed by that id); the others
/// are carried for completeness / fallback.
nonisolated struct ServerDeletion: Codable, Sendable {
    let contentHash: String?
    let conversationId: String?
    let messageId: String?

    enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash"
        case conversationId = "conversation_id"
        case messageId = "message_id"
    }
}

nonisolated struct ServerDeltaResponse: Codable, Sendable {
    let messages: [ServerMessage]
    let conversations: [ServerConversationState]?
    let deletions: [ServerDeletion]?
    let cursor: Int64
}

nonisolated struct ServerRegisterResponse: Codable, Sendable {
    let id: String
    let token: String
}

nonisolated struct ServerSendResponse: Codable, Sendable {
    let id: String
}
