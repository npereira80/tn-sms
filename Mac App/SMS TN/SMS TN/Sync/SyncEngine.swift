//
//  SyncEngine.swift
//  SMS TN
//
//  Offline copy + delta sync (spec §3.2).
//
//  Rules implemented:
//  - Full local mirror of current Google Messages state.
//  - On reconnect, deltas are imported in both directions of state:
//    new remote messages are inserted; messages/conversations deleted
//    remotely are HARD-deleted locally. No tombstones, no archive.
//  - Dedup by protocol message ID (fallback: timestamp+sender+content
//    hash), so reconnect syncs never create duplicates.
//
//  Deletion mirroring detail: the web protocol does not push realtime
//  "message deleted" events, so deletions are detected by reconciling
//  local vs. remote message IDs. Every reconnect reconciles a recent
//  window per conversation; a full deep-verify pass (entire history)
//  runs after pairing and can be triggered from the app menu.
//

import Foundation
import os

actor SyncEngine {
    private let db: AppDatabase
    private let bridge: BridgeClient
    private let media: MediaStore
    private let log = Logger(subsystem: "macDroid.SMS-TN", category: "sync")
    private var syncing = false

    /// Overlap window re-checked on every reconnect (microseconds): 7 days.
    private let reconcileOverlap: Int64 = 7 * 24 * 3600 * 1_000_000
    private let pageSize = 50
    private let maxConversations = 500

    init(db: AppDatabase, bridge: BridgeClient, media: MediaStore) {
        self.db = db
        self.bridge = bridge
        self.media = media
    }

    // MARK: - Entry points

    /// Runs after every successful connect ("ready" event).
    func syncOnConnect(readyConversations: [PJConversation]) async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        do {
            let isFirstSync = (try? await db.kvGet("initialSyncDone")) == nil
            try await syncConversationList(seed: readyConversations)
            if isFirstSync {
                try await fullHistoryImport()
                try await db.kvSet("initialSyncDone", "1")
                try await db.kvSet("lastDeepVerify", String(Date().timeIntervalSince1970))
            } else {
                try await reconcileRecentWindows()
            }
            await media.drainQueue()
            await media.garbageCollect()
            log.info("Sync completed (firstSync: \(isFirstSync))")
        } catch {
            log.error("Sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Full-history verification: walks every conversation's complete
    /// remote history and removes any local message that no longer
    /// exists remotely. Heavy; runs after pairing and on demand.
    func deepVerify() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await syncConversationList(seed: [])
            let ids = try await db.conversationIDs()
            for conversationID in ids {
                try await reconcileConversation(conversationID: conversationID, since: 0)
            }
            try await db.kvSet("lastDeepVerify", String(Date().timeIntervalSince1970))
            await media.drainQueue()
            await media.garbageCollect()
            log.info("Deep verify completed for \(ids.count) conversations")
        } catch {
            log.error("Deep verify failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func withRetry<T>(attempts: Int, delay: Duration,
                              _ work: @Sendable () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                return try await work()
            } catch {
                lastError = error
                log.debug("Retryable sync call failed (attempt \(attempt + 1)/\(attempts)): \(error.localizedDescription, privacy: .public)")
                if attempt < attempts - 1 {
                    try? await Task.sleep(for: delay)
                }
            }
        }
        throw lastError ?? CancellationError()
    }

    // MARK: - Conversation list

    /// Mirrors the remote conversation list. Conversations that are gone
    /// remotely (or moved to DELETED status) are hard-deleted locally,
    /// cascading to their messages and media rows.
    private func syncConversationList(seed: [PJConversation]) async throws {
        var remote: [PJConversation] = []
        // Right after pairing/reconnect the long-poll session may still be
        // settling; retry the first request a few times before giving up.
        let inbox = try await withRetry(attempts: 5, delay: .seconds(2)) {
            try await self.bridge.listConversations(count: self.maxConversations, folder: 1)
        }
        remote.append(contentsOf: inbox)
        if let archived = try? await bridge.listConversations(count: maxConversations, folder: 2) {
            remote.append(contentsOf: archived)
        }
        // The ready event's list can contain entries the explicit list
        // call misses during startup; merge both.
        let fetchedIDs = Set(remote.map(\.conversationID))
        remote.append(contentsOf: seed.filter { !fetchedIDs.contains($0.conversationID) })

        for conversation in remote {
            try await db.upsertConversation(conversation)
        }

        let remoteIDs = Set(remote.filter { ($0.status?.name ?? "ACTIVE") != "DELETED" }
            .map(\.conversationID))
        let localIDs = try await db.conversationIDs()
        let gone = localIDs.subtracting(remoteIDs)
        if !gone.isEmpty {
            log.info("Hard-deleting \(gone.count) conversations removed remotely")
            try await db.deleteConversations(ids: Array(gone))
        }
    }

    // MARK: - Message import / reconcile

    /// First sync after pairing: import complete history everywhere.
    private func fullHistoryImport() async throws {
        let ids = try await db.conversationIDs()
        var done = 0
        for conversationID in ids {
            try await reconcileConversation(conversationID: conversationID, since: 0)
            done += 1
            log.debug("Initial import \(done)/\(ids.count)")
        }
    }

    /// Reconnect delta: reconcile a recent window per conversation
    /// (from last synced timestamp minus overlap).
    private func reconcileRecentWindows() async throws {
        let ids = try await db.conversationIDs()
        for conversationID in ids {
            let conv = try await db.conversation(id: conversationID)
            let lastSynced = conv?.lastSyncedMessageTimestamp ?? 0
            let since = max(0, lastSynced - reconcileOverlap)
            try await reconcileConversation(conversationID: conversationID, since: since)
        }
    }

    /// Fetches remote messages newest-first until reaching `since`
    /// (0 = entire history), upserts them, then hard-deletes local
    /// messages in the covered window that are missing remotely.
    private func reconcileConversation(conversationID: String, since: Int64) async throws {
        let myIDs = try await db.myParticipantIDs(conversationID: conversationID)
        var remoteIDs = Set<String>()
        var cursor: PJCursor?
        var oldestFetched = Int64.max
        var newestFetched: Int64 = 0
        var pages = 0

        while true {
            let resp = try await bridge.listMessages(conversationID: conversationID,
                                                     count: pageSize, cursor: cursor)
            let messages = resp.messages ?? []
            if messages.isEmpty { break }

            for message in messages {
                let ts = message.timestamp?.value ?? 0
                oldestFetched = min(oldestFetched, ts)
                newestFetched = max(newestFetched, ts)
                try await db.upsertMessage(message, myParticipantIDs: myIDs)
                if let record = MessageRecord.from(message, myParticipantIDs: myIDs) {
                    remoteIDs.insert(record.id)
                }
            }

            pages += 1
            let reachedWindowStart = oldestFetched <= since && since > 0
            let noMorePages = resp.cursor?.lastItemID == nil || messages.count < pageSize
            if reachedWindowStart || noMorePages || pages > 2000 { break }
            cursor = resp.cursor
        }

        guard newestFetched > 0 else {
            // Remote history is empty: mirror that state locally (window only).
            let windowStart = since
            let local = try await db.localMessageIDs(conversationID: conversationID, since: windowStart)
            if !local.isEmpty && since == 0 {
                try await db.deleteMessages(ids: Array(local))
            }
            return
        }

        // Hard-delete local rows missing remotely within the fetched window.
        let windowStart = max(since, since == 0 ? 0 : oldestFetched)
        let localIDs = try await db.localMessageIDs(conversationID: conversationID,
                                                    since: since == 0 ? 0 : windowStart)
        let gone = localIDs.subtracting(remoteIDs)
        if !gone.isEmpty {
            log.info("Hard-deleting \(gone.count) messages removed remotely in \(conversationID, privacy: .private)")
            try await db.deleteMessages(ids: Array(gone))
        }

        try await db.setLastSyncedMessageTimestamp(conversationID: conversationID,
                                                   timestamp: newestFetched)
    }

    // MARK: - Realtime handlers

    func handleRealtimeMessage(_ message: PJMessage) async {
        guard let conversationID = message.conversationID else { return }
        do {
            if try await db.conversation(id: conversationID) == nil {
                // New conversation we have not seen yet: fetch it.
                if let conv = try? await bridge.getConversation(id: conversationID) {
                    try await db.upsertConversation(conv)
                }
            }
            let myIDs = try await db.myParticipantIDs(conversationID: conversationID)
            try await db.upsertMessage(message, myParticipantIDs: myIDs)
            if let ts = message.timestamp?.value {
                try await db.setLastSyncedMessageTimestamp(conversationID: conversationID, timestamp: ts)
            }
            await media.drainQueue()
        } catch {
            log.error("Failed to store realtime message: \(error.localizedDescription, privacy: .public)")
        }
    }

    func handleRealtimeConversation(_ conversation: PJConversation) async {
        do {
            try await db.upsertConversation(conversation)
        } catch {
            log.error("Failed to store conversation update: \(error.localizedDescription, privacy: .public)")
        }
    }
}
