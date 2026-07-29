//
//  AppDatabase.swift
//  SMS TN
//
//  GRDB database setup + data access. SQLite file lives in
//  Application Support inside the sandbox container; protected by
//  macOS file protections + FileVault (spec §3.4).
//

import Foundation
import GRDB

nonisolated final class AppDatabase: Sendable {
    let pool: DatabasePool

    nonisolated static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("SMS TN", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func open() throws -> AppDatabase {
        let dir = try defaultDirectory()
        let url = dir.appendingPathComponent("messages.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        let db = AppDatabase(pool: pool)
        try db.migrate()
        return db
    }

    init(pool: DatabasePool) {
        self.pool = pool
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "conversation") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("lastMessageTimestamp", .integer).notNull().defaults(to: 0)
                t.column("unread", .boolean).notNull().defaults(to: false)
                t.column("isGroupChat", .boolean).notNull().defaults(to: false)
                t.column("defaultOutgoingID", .text).notNull().defaults(to: "")
                t.column("status", .text).notNull().defaults(to: "ACTIVE")
                t.column("readOnly", .boolean).notNull().defaults(to: false)
                t.column("avatarHexColor", .text)
                t.column("sendMode", .text)
                t.column("type", .text)
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("snippet", .text)
                t.column("snippetSender", .text)
                t.column("lastSyncedMessageTimestamp", .integer)
            }

            try db.create(table: "participant") { t in
                t.column("conversationID", .text).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("participantID", .text).notNull()
                t.column("fullName", .text)
                t.column("firstName", .text)
                t.column("number", .text)
                t.column("formattedNumber", .text)
                t.column("isMe", .boolean).notNull().defaults(to: false)
                t.column("avatarHexColor", .text)
                t.primaryKey(["conversationID", "participantID"])
            }

            try db.create(table: "message") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationID", .text).notNull().indexed()
                    .references("conversation", onDelete: .cascade)
                t.column("participantID", .text).notNull().defaults(to: "")
                t.column("timestamp", .integer).notNull().indexed()
                t.column("status", .text).notNull().defaults(to: "STATUS_UNKNOWN")
                t.column("textContent", .text).notNull().defaults(to: "")
                t.column("subject", .text)
                t.column("tmpID", .text).indexed()
                t.column("isFromMe", .boolean).notNull().defaults(to: false)
                t.column("reactionsJSON", .text)
                t.column("replyToMessageID", .text)
                t.column("pendingSend", .boolean).notNull().defaults(to: false)
            }
            try db.create(indexOn: "message", columns: ["conversationID", "timestamp"])

            try db.create(table: "media") { t in
                t.column("messageID", .text).notNull()
                    .references("message", onDelete: .cascade)
                t.column("mediaID", .text).notNull()
                t.column("mimeType", .text)
                t.column("fileName", .text)
                t.column("size", .integer).notNull().defaults(to: 0)
                t.column("width", .integer).notNull().defaults(to: 0)
                t.column("height", .integer).notNull().defaults(to: 0)
                t.column("decryptionKey", .text)
                t.column("thumbnailMediaID", .text)
                t.column("thumbnailDecryptionKey", .text)
                t.column("localFileName", .text)
                t.column("downloadState", .text).notNull().defaults(to: "pending")
                t.column("downloadAttempts", .integer).notNull().defaults(to: 0)
                t.primaryKey(["messageID", "mediaID"])
            }
            try db.create(indexOn: "media", columns: ["downloadState"])

            try db.create(table: "kv") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }

        migrator.registerMigration("v2_primaryNumber") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "primaryNumber", .text)
            }
        }

        try migrator.migrate(pool)
    }

    // MARK: - Conversations

    func upsertConversation(_ pj: PJConversation) async throws {
        let record = ConversationRecord.from(pj)
        let participants = (pj.participants ?? [])
            .compactMap { ParticipantRecord.from($0, conversationID: pj.conversationID) }
        try await pool.write { db in
            // DELETED conversations are removed outright: the local store
            // mirrors current state (spec §3.2).
            if record.status == "DELETED" || record.status == "SPAM_FOLDER" || record.status == "BLOCKED_FOLDER" {
                _ = try ConversationRecord.deleteOne(db, key: record.id)
                return
            }
            var toSave = record
            if let existing = try ConversationRecord.fetchOne(db, key: record.id) {
                toSave.lastSyncedMessageTimestamp = existing.lastSyncedMessageTimestamp
            }
            try toSave.save(db)
            if !participants.isEmpty {
                try ParticipantRecord
                    .filter(Column("conversationID") == record.id)
                    .deleteAll(db)
                for participant in participants {
                    try participant.save(db)
                }
            }
        }
    }

    func conversationIDs() async throws -> Set<String> {
        try await pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM conversation"))
        }
    }

    func deleteConversations(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await pool.write { db in
            try ConversationRecord.deleteAll(db, keys: ids)
        }
    }

    func conversation(id: String) async throws -> ConversationRecord? {
        try await pool.read { db in
            try ConversationRecord.fetchOne(db, key: id)
        }
    }

    func myParticipantIDs(conversationID: String) async throws -> Set<String> {
        try await pool.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT participantID FROM participant WHERE conversationID = ? AND isMe = 1",
                arguments: [conversationID]))
        }
    }

    func setLastSyncedMessageTimestamp(conversationID: String, timestamp: Int64) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE conversation SET lastSyncedMessageTimestamp = ? WHERE id = ?",
                arguments: [timestamp, conversationID])
        }
    }

    // MARK: - Messages

    /// Inserts or updates a message plus its media rows.
    /// Dedup: primary key is the protocol message ID (or fallback hash).
    /// If the message carries a tmpID matching an optimistic local row,
    /// that row is replaced (spec §3.2 dedup on import).
    func upsertMessage(_ pj: PJMessage, myParticipantIDs: Set<String>) async throws {
        guard var record = MessageRecord.from(pj, myParticipantIDs: myParticipantIDs) else { return }
        let mediaRecords = pj.mediaParts.compactMap { MediaRecord.from($0, messageID: record.id) }
        try await pool.write { db in
            if let tmpID = record.tmpID, !tmpID.isEmpty {
                try MessageRecord
                    .filter(Column("tmpID") == tmpID && Column("pendingSend") == true)
                    .deleteAll(db)
            }
            record.pendingSend = false
            try record.save(db)
            for media in mediaRecords {
                if var existing = try MediaRecord.fetchOne(
                    db, key: ["messageID": media.messageID, "mediaID": media.mediaID]) {
                    // Keep local download state; refresh keys/metadata.
                    existing.mimeType = media.mimeType ?? existing.mimeType
                    existing.decryptionKey = media.decryptionKey ?? existing.decryptionKey
                    existing.thumbnailMediaID = media.thumbnailMediaID ?? existing.thumbnailMediaID
                    existing.thumbnailDecryptionKey = media.thumbnailDecryptionKey ?? existing.thumbnailDecryptionKey
                    try existing.save(db)
                } else {
                    try media.save(db)
                }
            }
            // Bump the conversation summary for realtime arrivals.
            if let conv = try ConversationRecord.fetchOne(db, key: record.conversationID),
               record.timestamp >= conv.lastMessageTimestamp {
                try db.execute(
                    sql: """
                        UPDATE conversation
                        SET lastMessageTimestamp = ?, snippet = ?
                        WHERE id = ?
                        """,
                    arguments: [record.timestamp,
                                record.textContent.isEmpty ? conv.snippet : record.textContent,
                                record.conversationID])
            }
        }
    }

    // MARK: - v3 server sync

    /// Clears the local mirror so only server-sourced data remains. Used for
    /// the one-time migration off the v2 (Google-synced) store and for a
    /// manual "Reset & Re-sync". Server delta then re-pulls full history.
    func resetAll() async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM media")
            try db.execute(sql: "DELETE FROM message")
            try db.execute(sql: "DELETE FROM participant")
            try db.execute(sql: "DELETE FROM conversation")
            try db.execute(sql: "DELETE FROM kv")
        }
    }

    /// Maps SMS Sync server messages into the local conversation/message
    /// tables. Conversations are keyed by phone number (the server's
    /// conversation id); names/avatars are resolved in the UI via Contacts
    /// using `primaryNumber`. Idempotent: primary key is the server message id.
    func applyServerMessages(_ messages: [ServerMessage]) async throws {
        guard !messages.isEmpty else { return }
        try await pool.write { db in
            for m in messages {
                let convID = m.conversationId.isEmpty ? m.address : m.conversationId
                let tsMicros = m.ts * 1000
                let isMe = (m.direction == "out")

                var conv = try ConversationRecord.fetchOne(db, key: convID)
                    ?? ConversationRecord(
                        id: convID, name: "", lastMessageTimestamp: 0, unread: false,
                        isGroupChat: false, defaultOutgoingID: m.address, status: "ACTIVE",
                        readOnly: false, avatarHexColor: nil, sendMode: nil, type: "SMS",
                        pinned: false, snippet: nil, snippetSender: nil,
                        lastSyncedMessageTimestamp: nil, primaryNumber: m.address)
                if conv.primaryNumber == nil { conv.primaryNumber = m.address }
                if conv.defaultOutgoingID.isEmpty { conv.defaultOutgoingID = m.address }
                if tsMicros >= conv.lastMessageTimestamp {
                    conv.lastMessageTimestamp = tsMicros
                    conv.snippet = m.body
                    if !isMe { conv.unread = true }
                }
                try conv.save(db)

                let record = MessageRecord(
                    id: m.id, conversationID: convID, participantID: isMe ? "me" : m.address,
                    timestamp: tsMicros, status: m.status ?? "DELIVERED", textContent: m.body,
                    subject: nil, tmpID: nil, isFromMe: isMe, reactionsJSON: nil,
                    replyToMessageID: nil, pendingSend: false)
                try record.save(db)

                // MMS media: one media row per attachment, keyed by content hash.
                // decryptionKey is nil → MediaStore downloads it from GET /media.
                for att in m.attachments ?? [] {
                    if try MediaRecord.fetchOne(db, key: ["messageID": m.id, "mediaID": att.sha256]) != nil {
                        continue
                    }
                    let media = MediaRecord(
                        messageID: m.id, mediaID: att.sha256, mimeType: att.mime,
                        fileName: att.name, size: att.size ?? 0, width: 0, height: 0,
                        decryptionKey: nil, thumbnailMediaID: nil, thumbnailDecryptionKey: nil,
                        localFileName: nil, downloadState: MediaRecord.DownloadState.pending.rawValue,
                        downloadAttempts: 0)
                    try media.save(db)
                }
            }
        }
    }

    /// Applies server read state to local conversations (phone → Mac read sync).
    func applyConversationReadStates(_ states: [(id: String, unread: Bool)]) async throws {
        guard !states.isEmpty else { return }
        try await pool.write { db in
            for s in states {
                try db.execute(sql: "UPDATE conversation SET unread = ? WHERE id = ?",
                               arguments: [s.unread, s.id])
            }
        }
    }

    func insertPendingMessage(_ record: MessageRecord) async throws {
        try await pool.write { db in
            try record.save(db)
        }
    }

    func markPendingFailed(localID: String) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE message SET status = 'OUTGOING_FAILED_GENERIC' WHERE id = ? AND pendingSend = 1",
                arguments: [localID])
        }
    }

    /// After the bridge send call returns, record the server tmpID on the
    /// optimistic row so the incoming echo event replaces it (dedup).
    func updatePendingTmpID(localID: String, tmpID: String) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE message SET tmpID = ?, status = 'OUTGOING_COMPLETE' WHERE id = ? AND pendingSend = 1",
                arguments: [tmpID, localID])
        }
    }

    /// Wipes all local data (used on explicit unpair).
    func wipe() async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM conversation")
            try db.execute(sql: "DELETE FROM kv")
        }
    }

    func deleteMessages(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await pool.write { db in
            try MessageRecord.deleteAll(db, keys: ids)
        }
    }

    /// Removes conversations that have no messages left (e.g. after every
    /// message in a thread was tombstoned via /delta). Keeps the list tidy so a
    /// deleted thread doesn't linger as an empty row.
    func deleteEmptyConversations() async throws {
        _ = try await pool.write { db in
            try db.execute(sql: """
                DELETE FROM conversation
                WHERE id NOT IN (SELECT DISTINCT conversationID FROM message)
                """)
        }
    }

    /// IDs of locally stored messages in a conversation with
    /// timestamp >= since (excluding optimistic pending rows).
    func localMessageIDs(conversationID: String, since: Int64) async throws -> Set<String> {
        try await pool.read { db in
            Set(try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM message
                    WHERE conversationID = ? AND timestamp >= ? AND pendingSend = 0
                    """,
                arguments: [conversationID, since]))
        }
    }

    /// Count of unread inbound messages for the dock badge. Read state is stored
    /// per conversation (no per-message flag), so we count inbound messages in
    /// conversations still flagged unread, from each thread's most recent
    /// outbound message onward (sending a reply implies you'd seen everything
    /// before it). A thread you open is marked read, so it drops out entirely.
    func unreadMessageCount() async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM message m
                JOIN conversation c ON c.id = m.conversationID
                WHERE c.unread = 1
                  AND m.isFromMe = 0
                  AND m.pendingSend = 0
                  AND m.timestamp > COALESCE(
                        (SELECT MAX(m2.timestamp) FROM message m2
                          WHERE m2.conversationID = m.conversationID AND m2.isFromMe = 1), 0)
                """) ?? 0
        }
    }

    func latestMessage(conversationID: String) async throws -> MessageRecord? {
        try await pool.read { db in
            try MessageRecord
                .filter(Column("conversationID") == conversationID)
                .order(Column("timestamp").desc)
                .fetchOne(db)
        }
    }

    // MARK: - Media bookkeeping

    func pendingMedia(limit: Int) async throws -> [MediaRecord] {
        try await pool.read { db in
            try MediaRecord
                .filter(Column("downloadState") == MediaRecord.DownloadState.pending.rawValue)
                .filter(Column("downloadAttempts") < 5)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func updateMedia(_ record: MediaRecord) async throws {
        try await pool.write { db in
            try record.save(db)
        }
    }

    func media(forMessageIDs ids: [String]) async throws -> [MediaRecord] {
        guard !ids.isEmpty else { return [] }
        return try await pool.read { db in
            try MediaRecord.filter(ids.contains(Column("messageID"))).fetchAll(db)
        }
    }

    /// Local media filenames still referenced; used to garbage-collect
    /// files after hard deletes.
    func referencedMediaFiles() async throws -> Set<String> {
        try await pool.read { db in
            Set(try String.fetchAll(
                db, sql: "SELECT localFileName FROM media WHERE localFileName IS NOT NULL"))
        }
    }

    // MARK: - KV

    func kvGet(_ key: String) async throws -> String? {
        try await pool.read { db in
            try KVRecord.fetchOne(db, key: key)?.value
        }
    }

    func kvSet(_ key: String, _ value: String) async throws {
        try await pool.write { db in
            try KVRecord(key: key, value: value).save(db)
        }
    }
}
