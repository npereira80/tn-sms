//
//  AppModel.swift
//  SMS TN
//
//  Central coordinator: bridge lifecycle, event loop, sync, send path,
//  OTP routing, and observable state for the UI.
//

import AppKit
import Foundation
import GRDB
import os
import UniformTypeIdentifiers
import UserNotifications

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case needsPairing
        case ready
        case fatal(String)
    }

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case phoneNotResponding

        var label: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .reconnecting: return "Reconnecting…"
            case .phoneNotResponding: return "Phone not responding — check that your Android phone is on and online"
            }
        }
    }

    // Observable UI state
    private(set) var phase: Phase = .launching
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var pairingQR: String?
    private(set) var pairingError: String?
    private(set) var pairingEmoji: String?      // Gaia emoji to confirm on phone
    private(set) var googlePairingInProgress = false
    private(set) var conversations: [ConversationRecord] = []
    private(set) var typingConversationIDs: Set<String> = []
    var selectedConversationID: String?
    private(set) var threadMessages: [MessageRecord] = []
    private(set) var threadMedia: [String: [MediaRecord]] = [:]  // messageID -> media
    private(set) var syncRunning = false

    let otpCenter = OTPCenter()

    private var bridge: BridgeClient?          // v2 (dormant): Google web protocol
    private var db: AppDatabase?
    private var mediaStore: MediaStore?
    private var syncEngine: SyncEngine?

    // v3: self-hosted SMS Sync server transport.
    private var server: ServerClient?
    private var serverTask: Task<Void, Never>?
    private var deltaPollTask: Task<Void, Never>?
    private var pendingSendRequests: [String: String] = [:]   // server requestId -> local message id

    // Mac unified inbox: BlueBubbles (iMessage) receive-only polling client.
    private var bbTask: Task<Void, Never>?
    private(set) var bbConnected = false
    var showBBSettings = false   // drives the settings sheet (toolbar button + menu command)

    private var eventTask: Task<Void, Never>?
    private var qrRefreshTask: Task<Void, Never>?
    private var conversationObservationTask: Task<Void, Never>?
    private var threadObservationTask: Task<Void, Never>?
    private var typingClearTasks: [String: Task<Void, Never>] = [:]
    private let log = Logger(subsystem: "macDroid.SMS-TN", category: "app")

    var mediaStoreRef: MediaStore? { mediaStore }

    // MARK: - Startup

    func start() async {
        do {
            let db = try AppDatabase.open()
            self.db = db

            // The offline copy is readable immediately; no pairing screen in
            // v3 — the app is a client of the self-hosted server.
            observeConversations()
            phase = .ready

            let server = ServerClient()
            self.server = server

            // Media store for MMS attachments (downloads blobs from the server's
            // /media endpoint into the app's Media dir for the thread to render).
            self.mediaStore = try? MediaStore(db: db, server: server)

            Task {
                await requestNotificationPermission()
                otpCenter.registerNotificationCategory()
            }

            // iMessage via BlueBubbles (if configured in Settings).
            startBlueBubblesSync()

            connectionState = .connecting
            serverTask = Task { await runServerSync(server: server, db: db) }
            // Safety net: the realtime socket delivers read/delete/message events,
            // but a missed frame or a socket blip would otherwise leave the Mac
            // stale until relaunch. Re-pull the delta (which carries the full
            // read snapshot) on a timer so we always converge — mirrors the
            // Android client's 60s poll.
            deltaPollTask = Task { await runDeltaPolling(server: server, db: db) }
        } catch {
            phase = .fatal("Startup failed: \(error.localizedDescription)")
        }
    }

    func shutdown() async {
        serverTask?.cancel()
        deltaPollTask?.cancel()
        bbTask?.cancel()
        server?.close()
        eventTask?.cancel()
        qrRefreshTask?.cancel()
        await bridge?.disconnect()
    }

    // MARK: - v3 server sync

    private func runServerSync(server: ServerClient, db: AppDatabase) async {
        // One-time migration off the v2 local store: drop stale Google-synced
        // conversations so the Mac shows exactly what the server has (removes
        // the duplicate/old threads carried over from the libgm build).
        if !UserDefaults.standard.bool(forKey: "v3ResetDone") {
            try? await db.resetAll()
            UserDefaults.standard.set(true, forKey: "v3ResetDone")
        }

        // Initial history pull (delta since stored cursor; 0 = full history).
        do {
            try await server.ensureRegistered()
            let since = Int64((try? await db.kvGet("serverCursor")) ?? "") ?? 0
            syncRunning = true
            let delta = try await server.fetchDelta(since: since)
            try await db.applyServerMessages(delta.messages)
            if let states = delta.conversations {
                try? await db.applyConversationReadStates(states.map { ($0.id, $0.unread != 0) })
            }
            await applyServerDeletions(delta.deletions ?? [], db: db)
            if delta.cursor > 0 { try? await db.kvSet("serverCursor", String(delta.cursor)) }
            await mediaStore?.drainQueue()
            syncRunning = false
            connectionState = .connected
        } catch {
            syncRunning = false
            connectionState = .disconnected
            log.error("Server sync failed: \(error.localizedDescription, privacy: .public)")
        }

        // Realtime stream (self-reconnecting).
        for await event in server.events() {
            switch event {
            case .connected:
                connectionState = .connected
            case .disconnected:
                connectionState = .reconnecting
            case .message(let m):
                try? await db.applyServerMessages([m])
                if (m.attachments?.isEmpty == false) { await mediaStore?.drainQueue() }
                if let updated = m.updatedAt { try? await db.kvSet("serverCursor", String(updated)) }
                if m.direction == "in" { notifyIfNeededServer(m) }
            case .sendStatus(let requestId, let status):
                await handleServerSendStatus(requestId: requestId, status: status)
            case .conversationRead(let conversationId, let unread):
                try? await db.pool.write { dbConn in
                    try dbConn.execute(sql: "UPDATE conversation SET unread = ? WHERE id = ?",
                                       arguments: [unread, conversationId])
                }
            case .messageDeleted(let id, _):
                try? await db.deleteMessages(ids: [id])
            case .conversationDeleted(let conversationId):
                if selectedConversationID == conversationId { selectConversation(nil) }
                try? await db.deleteConversations(ids: [conversationId])
            }
        }
    }

    /// Periodic delta re-pull so read/delete/message state converges even if a
    /// realtime WebSocket frame was missed (e.g. socket reconnect). The initial
    /// history pull is done in `runServerSync`; this keeps us fresh thereafter.
    private func runDeltaPolling(server: ServerClient, db: AppDatabase) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled { break }
            do {
                let since = Int64((try? await db.kvGet("serverCursor")) ?? "") ?? 0
                let delta = try await server.fetchDelta(since: since)
                try await db.applyServerMessages(delta.messages)
                if let states = delta.conversations {
                    try? await db.applyConversationReadStates(states.map { ($0.id, $0.unread != 0) })
                }
                await applyServerDeletions(delta.deletions ?? [], db: db)
                await mediaStore?.drainQueue()
                if delta.cursor > since { try? await db.kvSet("serverCursor", String(delta.cursor)) }
            } catch {
                log.error("Periodic delta refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Apply deletion tombstones returned by /delta. The realtime
    /// `message_deleted` frame handles the live case, but a frame is lost
    /// whenever the socket is down (app closed, reconnecting), so the periodic
    /// delta pull must also converge deletes — otherwise a message deleted on
    /// the phone lingers on the Mac forever. Our local rows are keyed by the
    /// server nanoid, so we delete by `messageId`.
    private func applyServerDeletions(_ deletions: [ServerDeletion], db: AppDatabase) async {
        guard !deletions.isEmpty else { return }
        let ids = deletions.compactMap { $0.messageId }.filter { !$0.isEmpty }
        if !ids.isEmpty { try? await db.deleteMessages(ids: ids) }
        try? await db.deleteEmptyConversations()
    }

    // MARK: - BlueBubbles (iMessage) sync

    func startBlueBubblesSync() {
        bbTask?.cancel()
        guard BBConfig.isConfigured, let db else { bbConnected = false; return }
        bbTask = Task { await runBlueBubblesSync(db: db) }
    }

    /// Save + verify BlueBubbles settings, then (re)start sync. Returns false if
    /// the URL/password don't authenticate (nothing is persisted in that case).
    func configureBlueBubbles(urlString: String, password: String) async -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed),
              let client = BlueBubblesClient(config: (url: url, password: password)),
              await client.ping() else { return false }
        BBConfig.serverURL = url
        BBConfig.password = password
        startBlueBubblesSync()
        return true
    }

    /// Poll the BlueBubbles server for iMessage chats + new messages and merge
    /// them into the store (v1: receive/display, 1:1 chats). Text only for now.
    private func runBlueBubblesSync(db: AppDatabase) async {
        while !Task.isCancelled {
            guard let client = BlueBubblesClient() else { bbConnected = false; return }
            do {
                let chats = try await client.chats()
                bbConnected = true
                for chat in chats {
                    if Task.isCancelled { return }
                    let parts = chat.participants ?? []
                    guard chat.style == 45 || parts.count == 1,
                          let addr = parts.first?.address, !addr.isEmpty else { continue }
                    let convID = BBAddress.normalize(addr)
                    let key = "bbCursor:\(chat.guid)"
                    let cursor = Int64((try? await db.kvGet(key)) ?? "") ?? 0
                    let msgs = try await client.messages(chatGuid: chat.guid, afterMs: cursor)
                    if msgs.isEmpty { continue }
                    try await db.applyBBMessages(conversationID: convID, address: addr,
                                                 displayName: chat.displayName, msgs)
                    let newest = msgs.map { $0.dateCreated ?? 0 }.max() ?? cursor
                    if newest > cursor { try? await db.kvSet(key, String(newest)) }
                }
            } catch {
                bbConnected = false
                log.error("BlueBubbles sync failed: \(error.localizedDescription, privacy: .public)")
            }
            try? await Task.sleep(for: .seconds(20))
        }
    }

    /// Mark every conversation read locally and push the read-state to the server
    /// so the phone and other devices reflect it (File → Mark All Messages as Read).
    func markAllRead() {
        guard let db, let server else { return }
        let ids = conversations.filter(\.unread).map(\.id)
        Task {
            try? await db.pool.write { dbConn in
                try dbConn.execute(sql: "UPDATE conversation SET unread = 0")
            }
            for id in ids {
                try? await server.markRead(address: id, unread: false)
            }
        }
    }

    // MARK: - Delete (Mac -> server + synced clients; phone keeps its copy)

    func deleteMessage(_ messageID: String) {
        guard let db else { return }
        Task {
            try? await db.deleteMessages(ids: [messageID])   // optimistic local removal
            try? await server?.deleteMessages(ids: [messageID])
        }
    }

    func deleteThread(_ conversationID: String) {
        guard let db else { return }
        if selectedConversationID == conversationID { selectConversation(nil) }
        Task {
            try? await db.deleteConversations(ids: [conversationID])   // cascades messages
            try? await server?.deleteConversation(id: conversationID)
        }
    }

    /// Wipes the local mirror and re-pulls everything from the server.
    func resyncFromServer() {
        guard let db else { return }
        serverTask?.cancel()
        server?.close()
        connectionState = .connecting
        conversations = []
        threadMessages = []
        let fresh = ServerClient()
        self.server = fresh
        serverTask = Task {
            try? await db.resetAll()
            await runServerSync(server: fresh, db: db)
        }
    }

    private func handleServerSendStatus(requestId: String, status: String) async {
        guard let localID = pendingSendRequests[requestId], let db else { return }
        let mapped: String
        switch status {
        case "sent", "delivered": mapped = "OUTGOING_COMPLETE"
        case "failed": mapped = "OUTGOING_FAILED_GENERIC"
        default: mapped = "OUTGOING_SENDING"
        }
        try? await db.pool.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE message SET status = ?, pendingSend = 0 WHERE id = ?",
                arguments: [mapped, localID])
        }
        if status == "sent" || status == "delivered" || status == "failed" {
            pendingSendRequests[requestId] = nil
        }
    }

    private func notifyIfNeededServer(_ m: ServerMessage) {
        // OTP detection runs on every incoming text (spec §3.3).
        if !m.body.isEmpty { otpCenter.handleIncoming(text: m.body, sender: m.address) }

        let appActive = NSApp.isActive
        let viewingThread = selectedConversationID == m.conversationId
        if !appActive { NSApp.requestUserAttention(.informationalRequest) }
        guard !(appActive && viewingThread) else { return }
        guard OTPDetector.detect(in: m.body) == nil else { return }   // OTP notif already sent

        let content = UNMutableNotificationContent()
        content.title = m.address
        content.body = m.body.isEmpty ? "Message" : String(m.body.prefix(140))
        content.sound = .default
        content.userInfo = ["conversationID": m.conversationId]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Pairing

    /// QR pairing (legacy; many current Google Messages versions no longer
    /// expose the QR scanner — use Google-account pairing instead).
    func beginPairing() {
        guard let bridge else { return }
        pairingError = nil
        qrRefreshTask?.cancel()
        qrRefreshTask = Task {
            do {
                try await bridge.configure(sessionJSON: nil)
                let qr = try await bridge.startQRLogin()
                pairingQR = qr
                // QR expires after ~30s; refresh until paired.
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(25))
                    guard !Task.isCancelled else { return }
                    pairingQR = try await bridge.refreshQR()
                }
            } catch {
                if !Task.isCancelled {
                    pairingError = "Could not start pairing: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelQRPairing() {
        qrRefreshTask?.cancel()
        pairingQR = nil
    }

    /// Google-account (Gaia) pairing: pass cookies harvested from a
    /// signed-in Google web session. The confirmation emoji arrives via
    /// the `gaia_emoji` event.
    func beginGoogleLogin(cookies: [String: String]) {
        guard let bridge else { return }
        qrRefreshTask?.cancel()
        pairingError = nil
        pairingEmoji = nil
        pairingQR = nil
        googlePairingInProgress = true
        Task {
            do {
                try await bridge.startGoogleLogin(cookies: cookies)
            } catch {
                googlePairingInProgress = false
                pairingError = "Could not start pairing: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Event loop

    private func startEventLoop() {
        guard let bridge else { return }
        eventTask = Task {
            for await event in bridge.events {
                await handle(event)
            }
        }
    }

    /// Marks the client connected and runs a sync. Used after pairing and
    /// after a successful reconnect, since this libgm build emits no
    /// "ready" event to hang that off.
    private func onConnected(readyConversations: [PJConversation]) {
        connectionState = .connected
        if phase != .ready { phase = .ready }
        guard !syncRunning else { return }
        syncRunning = true
        let engine = syncEngine
        Task {
            await engine?.syncOnConnect(readyConversations: readyConversations)
            await MainActor.run { self.syncRunning = false }
        }
    }

    private func handle(_ event: GMEvent) async {
        switch event {
        case .pairSuccessful(let phoneID):
            log.info("Paired with phone \(phoneID, privacy: .private)")
            qrRefreshTask?.cancel()
            pairingQR = nil
            pairingEmoji = nil
            googlePairingInProgress = false
            await persistSession()
            phase = .ready
            // libgm reconnects itself after pairing; this version emits no
            // "ready" event, so drive the connected+sync transition here.
            onConnected(readyConversations: [])

        case .gaiaEmoji(let emoji):
            pairingEmoji = emoji

        case .gaiaError(let message):
            googlePairingInProgress = false
            pairingEmoji = nil
            pairingError = "Pairing failed: \(message)"

        case .ready(_, let readyConversations):
            // Not emitted by the current libgm; handled for forward-compat.
            phase = .ready
            await persistSession()
            onConnected(readyConversations: readyConversations)

        case .message(let message, let isOld):
            await syncEngine?.handleRealtimeMessage(message)
            if !isOld {
                notifyIfNeeded(for: message)
            }

        case .conversation(let conversation):
            await syncEngine?.handleRealtimeConversation(conversation)

        case .typing(let conversationID, let started):
            setTypingIndicator(conversationID: conversationID, active: started)

        case .authTokenRefreshed:
            await persistSession()

        case .listenTemporaryError:
            connectionState = .reconnecting

        case .listenRecovered:
            connectionState = .connected

        case .phoneNotResponding:
            connectionState = .phoneNotResponding

        case .phoneRespondingAgain:
            connectionState = .connected

        case .listenFatal(let message):
            connectionState = .disconnected
            log.error("Listen fatal: \(message, privacy: .public)")

        case .pairRevoked, .gaiaLoggedOut:
            // The connection dropped its auth. Do NOT wipe the stored
            // session or force re-pairing: per the product decision, only
            // an explicit "Unpair phone" clears the login. Keep the
            // offline copy readable and stay signed in; a later reconnect
            // (or token refresh) can recover. The user can Unpair manually
            // if they truly want to re-pair.
            connectionState = .disconnected
            log.warning("Received logout/revoke event; keeping stored session")

        case .pingFailed(let message):
            log.warning("Ping failed: \(message, privacy: .public)")

        case .accountChange, .browserActive, .settingsUpdated, .userAlert,
             .noDataReceived, .unknown:
            break
        }
    }

    private func persistSession() async {
        guard let bridge else { return }
        do {
            let session = try await bridge.sessionJSON()
            try KeychainStore.session.write(session)
        } catch {
            log.error("Failed to persist session: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Observation (DB -> UI)

    private func observeConversations() {
        guard let db else { return }
        conversationObservationTask = Task {
            let observation = ValueObservation.tracking { dbConn in
                try ConversationRecord
                    .order(Column("pinned").desc, Column("lastMessageTimestamp").desc)
                    .fetchAll(dbConn)
            }
            do {
                for try await records in observation.values(in: db.pool) {
                    self.conversations = records
                    await self.updateDockBadge()
                }
            } catch {
                log.error("Conversation observation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Red dock badge showing the number of unread messages (empty when zero).
    private func updateDockBadge() async {
        guard let db else { NSApp.dockTile.badgeLabel = nil; return }
        let count = (try? await db.unreadMessageCount()) ?? 0
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    func selectConversation(_ id: String?) {
        selectedConversationID = id
        threadObservationTask?.cancel()
        threadMessages = []
        threadMedia = [:]
        guard let id, let db else { return }

        threadObservationTask = Task {
            let observation = ValueObservation.tracking { dbConn -> ([MessageRecord], [MediaRecord]) in
                let messages = try MessageRecord
                    .filter(Column("conversationID") == id)
                    .order(Column("timestamp").asc)
                    .fetchAll(dbConn)
                let media = try MediaRecord
                    .filter(messages.map(\.id).contains(Column("messageID")))
                    .fetchAll(dbConn)
                return (messages, media)
            }
            do {
                for try await (messages, media) in observation.values(in: db.pool) {
                    guard !Task.isCancelled else { return }
                    self.threadMessages = messages
                    self.threadMedia = Dictionary(grouping: media, by: \.messageID)
                }
            } catch {
                if !Task.isCancelled {
                    log.error("Thread observation failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        Task { await markThreadRead(conversationID: id) }
    }

    // MARK: - Send path

    func sendText(_ text: String) async {
        guard let conversationID = selectedConversationID,
              let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        await sendText(text, to: conversation)
    }

    private func sendText(_ text: String, to conversation: ConversationRecord) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // v3 server send path: enqueue on the server, which routes to the SIM
        // phone. Optimistic local row shows immediately; status updates via the
        // send_status WebSocket event. (Won't appear in Google Messages on the
        // phone — accepted limitation.)
        if let server, let db {
            let localID = "tmp:\(UUID().uuidString)"
            let pending = MessageRecord(
                id: localID, conversationID: conversation.id, participantID: "me",
                timestamp: Int64(Date().timeIntervalSince1970 * 1_000_000),
                status: "OUTGOING_SENDING", textContent: trimmed, subject: nil, tmpID: nil,
                isFromMe: true, reactionsJSON: nil, replyToMessageID: nil, pendingSend: true)
            do {
                try await db.insertPendingMessage(pending)
                let to = conversation.primaryNumber ?? conversation.id
                let requestId = try await server.postSend(to: to, body: trimmed)
                if !requestId.isEmpty { pendingSendRequests[requestId] = localID }
            } catch {
                log.error("Server send failed: \(error.localizedDescription, privacy: .public)")
                try? await db.markPendingFailed(localID: localID)
            }
            return
        }

        // v2 bridge send path (dormant).
        guard let bridge, let db else { return }

        let localID = "tmp:\(UUID().uuidString)"
        let pending = MessageRecord(
            id: localID,
            conversationID: conversation.id,
            participantID: conversation.defaultOutgoingID,
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000_000),
            status: "OUTGOING_SENDING",
            textContent: trimmed,
            subject: nil,
            tmpID: nil,
            isFromMe: true,
            reactionsJSON: nil,
            replyToMessageID: nil,
            pendingSend: true
        )
        do {
            try await db.insertPendingMessage(pending)
            let result = try await bridge.sendText(
                conversationID: conversation.id,
                participantID: conversation.defaultOutgoingID,
                text: trimmed,
                forceRCS: conversation.type == "RCS")
            try await db.updatePendingTmpID(localID: localID, tmpID: result.tmpID)
        } catch {
            log.error("Send failed: \(error.localizedDescription, privacy: .public)")
            try? await db.markPendingFailed(localID: localID)
        }
    }

    /// Starts (or opens) a conversation for the given phone numbers and
    /// optionally sends a first message. Returns true on success.
    @discardableResult
    func startNewConversation(numbers: [String], message: String) async -> Bool {
        guard let bridge, let db else { return false }
        let cleaned = numbers.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return false }
        do {
            let pj = try await bridge.startConversation(numbers: cleaned)
            try await db.upsertConversation(pj)
            let record = ConversationRecord.from(pj)
            selectConversation(record.id)
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                await sendText(trimmed, to: record)
            }
            return true
        } catch {
            log.error("Start conversation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func sendAttachment(fileURL: URL, caption: String) async {
        do {
            let data = try Data(contentsOf: fileURL)
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?
                .preferredMIMEType ?? "application/octet-stream"
            await sendAttachmentData(data, fileName: fileURL.lastPathComponent,
                                     mimeType: mimeType, caption: caption)
        } catch {
            log.error("Attachment read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sends raw attachment bytes (e.g. from the Photos picker).
    func sendAttachmentData(_ data: Data, fileName: String, mimeType: String, caption: String) async {
        guard let bridge, let db,
              let conversationID = selectedConversationID,
              let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let localID = "tmp:\(UUID().uuidString)"
        let pending = MessageRecord(
            id: localID,
            conversationID: conversationID,
            participantID: conversation.defaultOutgoingID,
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000_000),
            status: "OUTGOING_SENDING",
            textContent: caption.isEmpty ? "📎 \(fileName)" : caption,
            subject: nil,
            tmpID: nil,
            isFromMe: true,
            reactionsJSON: nil,
            replyToMessageID: nil,
            pendingSend: true
        )
        do {
            try await db.insertPendingMessage(pending)
            let mediaJSON = try await bridge.uploadMedia(data: data, fileName: fileName, mimeType: mimeType)
            let result = try await bridge.sendMedia(
                conversationID: conversationID,
                participantID: conversation.defaultOutgoingID,
                mediaContentJSON: mediaJSON,
                caption: caption,
                forceRCS: conversation.type == "RCS")
            try await db.updatePendingTmpID(localID: localID, tmpID: result.tmpID)
        } catch {
            log.error("Attachment send failed: \(error.localizedDescription, privacy: .public)")
            try? await db.markPendingFailed(localID: localID)
        }
    }

    // MARK: - Conversation actions

    func markThreadRead(conversationID: String) async {
        guard let db else { return }
        // Clear the unread flag locally first for an immediate UI response.
        try? await db.pool.write { dbConn in
            try dbConn.execute(sql: "UPDATE conversation SET unread = 0 WHERE id = ?",
                               arguments: [conversationID])
        }
        // v3: push the read-state to the SMS server so the Android phone and any
        // other client reflect it (the conversation id is the normalized address).
        try? await server?.markRead(address: conversationID, unread: false)
        // v2 bridge read receipt (dormant).
        if let bridge, connectionState == .connected,
           let latest = try? await db.latestMessage(conversationID: conversationID),
           !latest.pendingSend {
            try? await bridge.markRead(conversationID: conversationID, messageID: latest.id)
        }
    }

    private var lastTypingPing = Date.distantPast
    func userIsTyping() {
        guard let bridge, let conversationID = selectedConversationID,
              connectionState == .connected else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTypingPing) > 4 else { return }
        lastTypingPing = now
        Task { try? await bridge.setTyping(conversationID: conversationID) }
    }

    func retryConnect() {
        // v3: restart the server sync (history pull + realtime stream).
        if let server, let db {
            serverTask?.cancel()
            server.close()
            connectionState = .connecting
            let fresh = ServerClient()
            self.server = fresh
            serverTask = Task { await runServerSync(server: fresh, db: db) }
            return
        }
        // v2 bridge (dormant).
        guard let bridge else { return }
        connectionState = .connecting
        Task {
            do {
                try await bridge.connect()
                onConnected(readyConversations: [])
            } catch {
                connectionState = .disconnected
            }
        }
    }

    func runDeepVerify() {
        guard let syncEngine else { return }
        syncRunning = true
        Task {
            await syncEngine.deepVerify()
            await MainActor.run { self.syncRunning = false }
        }
    }

    func unpair() async {
        guard let bridge else { return }
        try? await bridge.unpair()
        await bridge.disconnect()
        try? KeychainStore.session.delete()
        try? await db?.wipe()
        await mediaStore?.garbageCollect()
        conversations = []
        threadMessages = []
        selectedConversationID = nil
        connectionState = .disconnected
        phase = .needsPairing
    }

    // MARK: - Typing indicator + notifications

    private func setTypingIndicator(conversationID: String, active: Bool) {
        typingClearTasks[conversationID]?.cancel()
        if active {
            typingConversationIDs.insert(conversationID)
            typingClearTasks[conversationID] = Task {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                typingConversationIDs.remove(conversationID)
            }
        } else {
            typingConversationIDs.remove(conversationID)
        }
    }

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func notifyIfNeeded(for message: PJMessage) {
        let fromMe = message.senderParticipant?.isMe ?? false
        guard !fromMe else { return }
        let text = message.textContent
        let sender = message.senderParticipant?.fullName
            ?? message.senderParticipant?.formattedNumber
            ?? conversations.first(where: { $0.id == message.conversationID })?.name
            ?? "New message"

        // OTP detection runs on every incoming text (spec §3.3).
        if !text.isEmpty {
            otpCenter.handleIncoming(text: text, sender: sender)
        }

        let appActive = NSApp.isActive
        let viewingThread = selectedConversationID == message.conversationID

        // Bounce the dock icon once when a message arrives and the app
        // isn't frontmost.
        if !appActive {
            NSApp.requestUserAttention(.informationalRequest)
        }

        guard !(appActive && viewingThread) else { return }
        guard OTPDetector.detect(in: text) == nil else { return } // OTP notification already sent

        let content = UNMutableNotificationContent()
        content.title = sender
        content.body = text.isEmpty ? "Attachment" : String(text.prefix(140))
        content.sound = .default
        if let conversationID = message.conversationID {
            content.userInfo = ["conversationID": conversationID]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
