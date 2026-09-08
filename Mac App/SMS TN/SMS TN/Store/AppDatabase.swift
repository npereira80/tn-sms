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

        migrator.registerMigration("v3_messageService") { db in
            try db.alter(table: "message") { t in
                t.add(column: "service", .text).notNull().defaults(to: "SMS")
            }
        }

        try migrator.migrate(pool)
    }

    // MARK: - Conversations

    func conversationIDs() async throws -> Set<String> {
        try await pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM conversation"))
        }
    }

    /// Existing conversations keyed by [BBAddress.matchKey], for resolving an
    /// address to the thread it already belongs to.
    ///
    /// Where two rows share a key — the state this is meant to stop happening —
    /// the one with the most recent activity wins, so ingest converges on the
    /// thread actually in use rather than flip-flopping between them.
    static func conversationsByMatchKey(_ db: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, primaryNumber FROM conversation
            ORDER BY lastMessageTimestamp ASC
            """)
        var map: [String: String] = [:]
        for row in rows {
            let id: String = row["id"]
            let number: String? = row["primaryNumber"]
            let key = BBAddress.matchKey(number ?? id)
            guard !key.isEmpty else { continue }
            map[key] = id      // ascending order, so the newest row overwrites
        }
        return map
    }

    /// Create (or fetch) the SMS conversation for a normalized address, so a
    /// thread can be started before any message exists in it.
    ///
    /// Mirrors the row `applyServerMessages` would build for an incoming message
    /// from the same address, so the conversation the person composes into is the
    /// same one the reply lands in.
    func ensureSmsConversation(id: String, address: String) async throws -> ConversationRecord {
        try await pool.write { db in
            if let existing = try ConversationRecord.fetchOne(db, key: id) { return existing }
            // Also match on significant digits, so composing to a national
            // number reuses the thread created from an international one.
            let key = BBAddress.matchKey(address)
            if !key.isEmpty,
               let existingID = try Self.conversationsByMatchKey(db)[key],
               let existing = try ConversationRecord.fetchOne(db, key: existingID) {
                return existing
            }
            let record = ConversationRecord(
                id: id, name: "", lastMessageTimestamp: Int64(Date().timeIntervalSince1970 * 1_000_000),
                unread: false, isGroupChat: false, defaultOutgoingID: address, status: "ACTIVE",
                readOnly: false, avatarHexColor: nil, sendMode: nil, type: "SMS",
                pinned: false, snippet: nil, snippetSender: nil,
                lastSyncedMessageTimestamp: nil, primaryNumber: address)
            try record.insert(db)
            return record
        }
    }

    /// This phone's own number, as reported on any
    /// conversation, or nil if it never has.
    ///
    /// The only trustworthy source of the account's country: the Mac's locale
    /// describes the person's language settings rather than their carrier, so a
    /// Portuguese line on a Mac set to English would read as US.
    func myPhoneNumber() async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT number FROM participant
                WHERE isMe = 1 AND number IS NOT NULL AND number <> ''
                LIMIT 1
                """)
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

    func setLastSyncedMessageTimestamp(conversationID: String, timestamp: Int64) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE conversation SET lastSyncedMessageTimestamp = ? WHERE id = ?",
                arguments: [timestamp, conversationID])
        }
    }

    // MARK: - Messages

    // MARK: - Server sync

    /// Clears the local mirror so only server-sourced data remains. Used for
    /// the one-time migration off the old Google-synced store and for a
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
            // Existing threads indexed by significant digits, so a number that
            // arrives in a different format than last time lands in the thread
            // it already has rather than starting a second one.
            //
            // This is where the split actually happened: the server keys a
            // conversation on the address as received, so sending to
            // "916309003" and getting the reply back as "+351916309003" — which
            // is what the carrier does — produced two rows for one person.
            var threadsByNumber = try Self.conversationsByMatchKey(db)

            for m in messages {
                let serverID = m.conversationId.isEmpty ? m.address : m.conversationId
                let matchKey = BBAddress.matchKey(m.address)
                let convID = matchKey.isEmpty ? serverID : (threadsByNumber[matchKey] ?? serverID)
                if !matchKey.isEmpty { threadsByNumber[matchKey] = convID }
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

                // Retire the optimistic row this message is the real version of.
                //
                // Sending inserts a local "tmp:" row so the bubble appears at
                // once, and the same message then comes back in the delta under
                // the server's id. Nothing reconciled the two — the send_status
                // event only updated the pending row's status — so every sent
                // message showed twice.
                //
                // Matched on conversation, direction and text rather than an id,
                // because the local row was created before the server had one.
                // Exactly one row is removed per ingested message, so sending
                // the same words twice retires two pendings rather than both at
                // once.
                if isMe {
                    try db.execute(
                        sql: """
                        DELETE FROM message WHERE id = (
                            SELECT id FROM message
                            WHERE pendingSend = 1 AND isFromMe = 1
                              AND conversationID = ? AND textContent = ?
                            ORDER BY timestamp ASC
                            LIMIT 1
                        )
                        """,
                        arguments: [convID, m.body])
                }

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

    /// Store iMessage messages from the BlueBubbles server into a conversation
    /// keyed by the participant's normalized address, so they merge with that
    /// contact's SMS thread. Each row is tagged service="iMessage" for colouring.
    func applyBBMessages(conversationID requestedID: String, address: String,
                         displayName: String?, _ messages: [BBMessage]) async throws {
        guard !messages.isEmpty else { return }
        try await pool.write { db in
            // Merge into the contact's existing thread whatever format their
            // iMessage handle arrived in — the whole point of keying these on
            // the phone number is that SMS and iMessage share one conversation,
            // and that fails if one side is national and the other isn't.
            let key = BBAddress.matchKey(address)
            let convID = key.isEmpty
                ? requestedID
                : (try Self.conversationsByMatchKey(db)[key] ?? requestedID)

            for m in messages {
                let tsMicros = (m.dateCreated ?? 0) * 1000
                let isMe = m.isFromMe ?? false
                var conv = try ConversationRecord.fetchOne(db, key: convID)
                    ?? ConversationRecord(
                        id: convID, name: displayName ?? "", lastMessageTimestamp: 0, unread: false,
                        isGroupChat: false, defaultOutgoingID: address, status: "ACTIVE",
                        readOnly: false, avatarHexColor: nil, sendMode: nil, type: "iMessage",
                        pinned: false, snippet: nil, snippetSender: nil,
                        lastSyncedMessageTimestamp: nil, primaryNumber: address)
                if conv.primaryNumber == nil { conv.primaryNumber = address }
                if tsMicros >= conv.lastMessageTimestamp {
                    conv.lastMessageTimestamp = tsMicros
                    conv.snippet = m.text
                    if !isMe { conv.unread = true }
                }
                try conv.save(db)

                let rec = MessageRecord(
                    id: m.guid, conversationID: convID, participantID: isMe ? "me" : address,
                    timestamp: tsMicros, status: "DELIVERED", textContent: m.text ?? "",
                    subject: nil, tmpID: nil, isFromMe: isMe, reactionsJSON: nil,
                    replyToMessageID: nil, pendingSend: false, service: "iMessage")
                try rec.save(db)
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

    func deleteMessages(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await pool.write { db in
            // Which threads are affected — read before the rows are gone.
            let affected = Set(try String.fetchAll(
                db,
                sql: "SELECT DISTINCT conversationID FROM message WHERE id IN (\(Self.placeholders(ids.count)))",
                arguments: StatementArguments(ids)))

            try MessageRecord.deleteAll(db, keys: ids)

            for conversationID in affected {
                try Self.refreshSummary(db, conversationID: conversationID)
            }
        }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    /// Repoint a conversation's preview at its newest surviving message.
    ///
    /// The list row shows `snippet` and `lastMessageTimestamp`, both cached on the
    /// conversation. Deleting the newest message left them describing a message
    /// that no longer exists, so the row kept showing text you'd just removed.
    ///
    /// A message with no text of its own (an attachment) contributes an empty
    /// snippet rather than inheriting the previous one — showing the wrong text is
    /// worse than showing none.
    static func refreshSummary(_ db: Database, conversationID: String) throws {
        let latest = try MessageRecord
            .filter(Column("conversationID") == conversationID)
            .order(Column("timestamp").desc)
            .fetchOne(db)

        guard let latest else {
            // Nothing left. Leave the row for deleteEmptyConversations to remove,
            // but stop advertising a message that's gone.
            try db.execute(
                sql: "UPDATE conversation SET snippet = NULL WHERE id = ?",
                arguments: [conversationID])
            return
        }

        try db.execute(
            sql: """
                UPDATE conversation
                SET lastMessageTimestamp = ?, snippet = ?
                WHERE id = ?
                """,
            arguments: [latest.timestamp,
                        latest.textContent.isEmpty ? nil : latest.textContent,
                        conversationID])
    }

    /// Fix conversations whose cached preview no longer matches their messages.
    ///
    /// Runs at launch, for threads left stale by a build that deleted messages
    /// without refreshing the summary. Only touches rows that are actually wrong.
    func repairConversationSummaries() async throws {
        _ = try await pool.write { db in
            let stale = try String.fetchAll(db, sql: """
                SELECT c.id FROM conversation c
                LEFT JOIN (SELECT conversationID, MAX(timestamp) AS newest
                           FROM message GROUP BY conversationID) m
                       ON m.conversationID = c.id
                WHERE m.newest IS NOT NULL AND c.lastMessageTimestamp <> m.newest
                """)
            for conversationID in stale {
                try Self.refreshSummary(db, conversationID: conversationID)
            }
            return stale.count
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
