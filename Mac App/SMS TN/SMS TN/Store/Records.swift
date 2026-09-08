//
//  Records.swift
//  SMS TN
//
//  GRDB record types for the local offline mirror (spec §3.2).
//  The store mirrors current state: no tombstones, no archive of deleted
//  messages.
//

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

}

// The `participant` table it mirrored is still created by the migrations and
// still holds rows from the Google era, but only that protocol ever wrote or
// read it: a thread's other party is resolved from the address now, through
// Contacts. Dropping the table would need a migration, so it is left in place
// and simply unused.

nonisolated struct MessageRecord: Codable, Identifiable, Hashable, Sendable,
    FetchableRecord, PersistableRecord {
    static let databaseTableName = "message"

    var id: String                    // server message id, or a local "tmp:" id
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

    var decodedReactions: [ReactionEntry] {
        guard let reactionsJSON,
              let entries = try? JSONDecoder().decode([ReactionEntry].self,
                                                      from: Data(reactionsJSON.utf8)) else {
            return []
        }
        return entries
    }
}

/// A tapback on a message, as stored in `MessageRecord.reactionsJSON`.
///
/// Nothing writes this any more: the only source was the Google protocol.
/// Kept because the rows already in the database still decode through it and
/// the thread renders them, and because BlueBubbles does carry tapbacks, so
/// this is the shape an iMessage reaction would land in.
nonisolated struct ReactionEntry: Codable, Sendable {
    var data: ReactionData?
    var participantIDs: [String]?
}

nonisolated struct ReactionData: Codable, Sendable {
    var unicode: String?
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
    /// Base64 key for a blob that was synced from Google. Only ever set on rows
    /// from that era, and unusable now: those blobs were fetched through the
    /// bridge. Kept so the existing rows still decode.
    var decryptionKey: String?
    var thumbnailMediaID: String?
    var thumbnailDecryptionKey: String?
    var localFileName: String?           // file in the app's Media directory
    var downloadState: String
    var downloadAttempts: Int

    var state: DownloadState { DownloadState(rawValue: downloadState) ?? .pending }

    var isImage: Bool { mimeType?.hasPrefix("image/") ?? false }
    var isVideo: Bool { mimeType?.hasPrefix("video/") ?? false }
    var isAudio: Bool { mimeType?.hasPrefix("audio/") ?? false }

}

/// Simple key-value store for sync bookkeeping.
nonisolated struct KVRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "kv"
    var key: String
    var value: String
}
