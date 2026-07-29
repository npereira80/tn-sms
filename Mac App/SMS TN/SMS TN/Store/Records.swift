//
//  Records.swift
//  SMS TN
//
//  GRDB record types for the local offline mirror (spec §3.2).
//  The local store mirrors current Google Messages state: no tombstones,
//  no archive of deleted messages.
//

import CryptoKit
import Foundation
import GRDB

nonisolated struct ConversationRecord: Codable, Identifiable, Hashable, Sendable,
    FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversation"

    var id: String                    // conversationID
    var name: String
    var lastMessageTimestamp: Int64   // microseconds
    var unread: Bool
    var isGroupChat: Bool
    var defaultOutgoingID: String
    var status: String                // ACTIVE / ARCHIVED / DELETED / ...
    var readOnly: Bool
    var avatarHexColor: String?
    var sendMode: String?
    var type: String?                 // SMS / RCS
    var pinned: Bool
    var snippet: String?              // latest message display content
    var snippetSender: String?
    var lastSyncedMessageTimestamp: Int64?
    var primaryNumber: String?        // other participant's number (contact match)

    var lastMessageDate: Date {
        Date(timeIntervalSince1970: TimeInterval(lastMessageTimestamp) / 1_000_000)
    }

    nonisolated static func from(_ pj: PJConversation) -> ConversationRecord {
        ConversationRecord(
            id: pj.conversationID,
            name: pj.name ?? "",
            lastMessageTimestamp: pj.lastMessageTimestamp?.value ?? 0,
            unread: pj.unread ?? false,
            isGroupChat: pj.isGroupChat ?? false,
            defaultOutgoingID: pj.defaultOutgoingID ?? "",
            status: pj.status?.name ?? "ACTIVE",
            readOnly: pj.readOnly ?? false,
            avatarHexColor: pj.avatarHexColor,
            sendMode: pj.sendMode?.name,
            type: pj.type?.name,
            pinned: pj.pinned ?? false,
            snippet: pj.latestMessage?.displayContent,
            snippetSender: pj.latestMessage?.displayName,
            lastSyncedMessageTimestamp: nil,
            primaryNumber: primaryNumber(from: pj)
        )
    }

    private static func primaryNumber(from pj: PJConversation) -> String? {
        let other = (pj.participants ?? []).first { !($0.isMe ?? false) }
        return other?.ID?.number ?? other?.formattedNumber
    }
}

nonisolated struct ParticipantRecord: Codable, Hashable, Sendable,
    FetchableRecord, PersistableRecord {
    static let databaseTableName = "participant"

    var conversationID: String
    var participantID: String
    var fullName: String?
    var firstName: String?
    var number: String?
    var formattedNumber: String?
    var isMe: Bool
    var avatarHexColor: String?

    var displayName: String {
        if let fullName, !fullName.isEmpty { return fullName }
        if let formattedNumber, !formattedNumber.isEmpty { return formattedNumber }
        return number ?? participantID
    }

    nonisolated static func from(_ pj: PJParticipant, conversationID: String) -> ParticipantRecord? {
        guard let participantID = pj.ID?.participantID else { return nil }
        return ParticipantRecord(
            conversationID: conversationID,
            participantID: participantID,
            fullName: pj.fullName,
            firstName: pj.firstName,
            number: pj.ID?.number,
            formattedNumber: pj.formattedNumber,
            isMe: pj.isMe ?? false,
            avatarHexColor: pj.avatarHexColor
        )
    }
}

nonisolated struct MessageRecord: Codable, Identifiable, Hashable, Sendable,
    FetchableRecord, PersistableRecord {
    static let databaseTableName = "message"

    var id: String                    // messageID from protocol, or fallback identity hash
    var conversationID: String
    var participantID: String         // sender
    var timestamp: Int64              // microseconds
    var status: String
    var textContent: String
    var subject: String?
    var tmpID: String?
    var isFromMe: Bool
    var reactionsJSON: String?
    var replyToMessageID: String?
    var pendingSend: Bool             // optimistic local row awaiting server echo
    var service: String = "SMS"       // "SMS" | "MMS" | "iMessage" — drives bubble colour

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000_000)
    }

    var isIMessage: Bool { service == "iMessage" }

    var isFailed: Bool { status.hasPrefix("OUTGOING_FAILED") || status == "OUTGOING_CANCELED" }

    /// Fallback identity per spec §3.2: timestamp + sender + content hash,
    /// used only when the protocol does not provide a message ID.
    /// Uses SHA-256 so the identity is stable across app launches.
    nonisolated static func fallbackIdentity(timestamp: Int64, sender: String, content: String) -> String {
        let digest = SHA256.hash(data: Data("\(timestamp)|\(sender)|\(content)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(24)
        return "fb:\(hex)"
    }

    nonisolated static func from(_ pj: PJMessage, myParticipantIDs: Set<String>) -> MessageRecord? {
        guard let conversationID = pj.conversationID else { return nil }
        let sender = pj.participantID ?? ""
        let timestamp = pj.timestamp?.value ?? 0
        let text = pj.textContent
        let id: String
        if let messageID = pj.messageID, !messageID.isEmpty {
            id = messageID
        } else {
            id = fallbackIdentity(timestamp: timestamp, sender: sender, content: text)
        }
        var reactionsJSON: String?
        if let reactions = pj.reactions, !reactions.isEmpty,
           let data = try? JSONEncoder().encode(reactions) {
            reactionsJSON = String(data: data, encoding: .utf8)
        }
        let isMe = pj.senderParticipant?.isMe
            ?? myParticipantIDs.contains(sender)
        return MessageRecord(
            id: id,
            conversationID: conversationID,
            participantID: sender,
            timestamp: timestamp,
            status: pj.messageStatus?.status?.name ?? "STATUS_UNKNOWN",
            textContent: text,
            subject: pj.subject,
            tmpID: pj.tmpID,
            isFromMe: isMe,
            reactionsJSON: reactionsJSON,
            replyToMessageID: pj.replyMessage?.messageID,
            pendingSend: false
        )
    }

    var decodedReactions: [PJReactionEntry] {
        guard let reactionsJSON,
              let entries = try? JSONDecoder().decode([PJReactionEntry].self,
                                                      from: Data(reactionsJSON.utf8)) else {
            return []
        }
        return entries
    }
}

nonisolated struct MediaRecord: Codable, Hashable, Sendable,
    FetchableRecord, PersistableRecord {
    static let databaseTableName = "media"

    enum DownloadState: String, Codable, Sendable {
        case pending, downloaded, failed
    }

    var messageID: String
    var mediaID: String
    var mimeType: String?
    var fileName: String?
    var size: Int64
    var width: Int64
    var height: Int64
    var decryptionKey: String?           // base64, needed to (re)fetch from Google
    var thumbnailMediaID: String?
    var thumbnailDecryptionKey: String?
    var localFileName: String?           // file in the app's Media directory
    var downloadState: String
    var downloadAttempts: Int

    var state: DownloadState { DownloadState(rawValue: downloadState) ?? .pending }

    var isImage: Bool { mimeType?.hasPrefix("image/") ?? false }
    var isVideo: Bool { mimeType?.hasPrefix("video/") ?? false }
    var isAudio: Bool { mimeType?.hasPrefix("audio/") ?? false }

    nonisolated static func from(_ pj: PJMediaContent, messageID: String) -> MediaRecord? {
        guard let mediaID = pj.mediaID, !mediaID.isEmpty else { return nil }
        return MediaRecord(
            messageID: messageID,
            mediaID: mediaID,
            mimeType: pj.mimeType,
            fileName: pj.mediaName,
            size: pj.size?.value ?? 0,
            width: pj.dimensions?.width?.value ?? 0,
            height: pj.dimensions?.height?.value ?? 0,
            decryptionKey: pj.decryptionKey,
            thumbnailMediaID: pj.thumbnailMediaID,
            thumbnailDecryptionKey: pj.thumbnailDecryptionKey,
            localFileName: nil,
            downloadState: DownloadState.pending.rawValue,
            downloadAttempts: 0
        )
    }
}

/// Simple key-value store for sync bookkeeping.
nonisolated struct KVRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "kv"
    var key: String
    var value: String
}
