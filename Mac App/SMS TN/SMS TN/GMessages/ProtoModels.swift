//
//  ProtoModels.swift
//  SMS TN
//
//  Codable models for the protojson payloads produced by the Gmbridge
//  Go layer (canonical proto3 JSON mapping):
//  - int64 fields arrive as JSON strings -> ProtoInt64
//  - enum fields arrive as name strings, or numbers for unknown values -> ProtoEnum
//  - bytes fields arrive as standard base64 strings
//  - unset fields are omitted -> everything Optional
//

import Foundation

/// Decodes proto3 JSON int64 values (string or number).
nonisolated struct ProtoInt64: Codable, Hashable, Sendable {
    var value: Int64

    init(_ value: Int64) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self), let parsed = Int64(str) {
            value = parsed
        } else if let num = try? container.decode(Int64.self) {
            value = num
        } else if let dbl = try? container.decode(Double.self) {
            value = Int64(dbl)
        } else {
            value = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(value))
    }
}

/// Decodes proto3 JSON enum values (name string, or raw number for
/// values unknown to the emitting proto definition).
nonisolated struct ProtoEnum: Codable, Hashable, Sendable {
    var name: String?
    var number: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            name = str
        } else if let num = try? container.decode(Int.self) {
            number = num
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let name { try container.encode(name) } else { try container.encode(number ?? 0) }
    }

    func matches(_ candidate: String) -> Bool { name == candidate }
}

// MARK: - Conversations

nonisolated struct PJConversation: Codable, Sendable {
    var conversationID: String
    var name: String?
    var latestMessage: PJLatestMessage?
    var lastMessageTimestamp: ProtoInt64?
    var unread: Bool?
    var isGroupChat: Bool?
    var defaultOutgoingID: String?
    var status: ProtoEnum?
    var readOnly: Bool?
    var avatarHexColor: String?
    var latestMessageID: String?
    var sendMode: ProtoEnum?
    var participants: [PJParticipant]?
    var otherParticipants: [String]?
    var type: ProtoEnum?
    var pinned: Bool?
    var groupAvatarURL: String?
}

nonisolated struct PJLatestMessage: Codable, Sendable {
    var displayContent: String?
    var fromMe: ProtoInt64?
    var displayName: String?
}

nonisolated struct PJParticipant: Codable, Sendable {
    var ID: PJSmallInfo?
    var firstName: String?
    var fullName: String?
    var avatarHexColor: String?
    var isMe: Bool?
    var isVisible: Bool?
    var contactID: String?
    var formattedNumber: String?
}

nonisolated struct PJSmallInfo: Codable, Sendable {
    var type: ProtoEnum?
    var number: String?
    var participantID: String?
}

// MARK: - Messages

nonisolated struct PJMessage: Codable, Sendable {
    var messageID: String?
    var messageStatus: PJMessageStatus?
    var timestamp: ProtoInt64?
    var conversationID: String?
    var participantID: String?
    var messageInfo: [PJMessageInfo]?
    var type: ProtoInt64?
    var tmpID: String?
    var subject: String?
    var reactions: [PJReactionEntry]?
    var replyMessage: PJReplyMessage?
    var senderParticipant: PJParticipant?

    /// Concatenated text parts of the message.
    var textContent: String {
        (messageInfo ?? [])
            .compactMap { $0.messageContent?.content }
            .joined(separator: "\n")
    }

    var mediaParts: [PJMediaContent] {
        (messageInfo ?? []).compactMap(\.mediaContent)
    }
}

nonisolated struct PJMessageStatus: Codable, Sendable {
    var status: ProtoEnum?
    var subCode: ProtoInt64?
    var errMsg: String?
    var statusText: String?
}

nonisolated struct PJMessageInfo: Codable, Sendable {
    var actionMessageID: String?
    // proto3 JSON flattens the oneof: exactly one of these is present.
    var messageContent: PJMessageContent?
    var mediaContent: PJMediaContent?
}

nonisolated struct PJMessageContent: Codable, Sendable {
    var content: String?
}

nonisolated struct PJMediaContent: Codable, Sendable {
    var format: ProtoEnum?
    var mediaID: String?
    var mediaName: String?
    var size: ProtoInt64?
    var dimensions: PJDimensions?
    var thumbnailMediaID: String?
    var decryptionKey: String?           // base64
    var thumbnailDecryptionKey: String?  // base64
    var mimeType: String?
}

nonisolated struct PJDimensions: Codable, Sendable {
    var width: ProtoInt64?
    var height: ProtoInt64?
}

nonisolated struct PJReactionEntry: Codable, Sendable {
    var data: PJReactionData?
    var participantIDs: [String]?
}

nonisolated struct PJReactionData: Codable, Sendable {
    var unicode: String?
    var type: ProtoEnum?
}

nonisolated struct PJReplyMessage: Codable, Sendable {
    var messageID: String?
    var conversationID: String?
}

// MARK: - Responses

nonisolated struct PJListConversationsResponse: Codable, Sendable {
    var conversations: [PJConversation]?
}

nonisolated struct PJListMessagesResponse: Codable, Sendable {
    var messages: [PJMessage]?
    var totalMessages: ProtoInt64?
    var cursor: PJCursor?
}

nonisolated struct PJCursor: Codable, Sendable {
    var lastItemID: String?
    var lastItemTimestamp: ProtoInt64?
}

nonisolated struct PJSendResult: Codable, Sendable {
    var tmpID: String
    var status: String?
}

nonisolated struct PJThumbnailResponse: Codable, Sendable {
    nonisolated struct Thumbnail: Codable, Sendable {
        var identifier: String?
        var data: ThumbnailData?
    }
    nonisolated struct ThumbnailData: Codable, Sendable {
        var imageBuffer: String? // base64
    }
    var thumbnail: [Thumbnail]?
}

nonisolated enum PJ {
    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}
