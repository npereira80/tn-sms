package com.ikuteam.tnwatch.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import com.ikuteam.tnwatch.config.ConfigStore
import com.ikuteam.tnwatch.config.TnConfig
import com.ikuteam.tnwatch.net.BBChat
import com.ikuteam.tnwatch.net.BlueBubblesClient
import com.ikuteam.tnwatch.net.StreamClient
import com.ikuteam.tnwatch.net.SyncClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

enum class Status { NeedsConfig, FirstSync, Ready }

/**
 * Cache-first store for the watch.
 *
 * The local SQLite [Db] is the source of truth for the UI, so threads render
 * instantly and work with no network. Syncing is incremental: the SMS server's
 * /delta cursor and a per-chat iMessage cursor are persisted, so a launch fetches
 * only what's new instead of re-pulling history. Outbound messages go through an
 * on-disk outbox and are retried until they get through.
 */
class Repository(private val app: Context) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val db = Db(app)
    private val syncMutex = Mutex()

    private companion object { const val TAG = "TnWatch" }

    private val _chats = MutableStateFlow<List<UiChat>>(emptyList())
    val chats: StateFlow<List<UiChat>> = _chats

    private val _status = MutableStateFlow(Status.NeedsConfig)
    val status: StateFlow<Status> = _status

    private val _syncing = MutableStateFlow(false)
    val syncing: StateFlow<Boolean> = _syncing

    private val _net = MutableStateFlow(NetStatus())
    val net: StateFlow<NetStatus> = _net

    /** Bumped whenever stored messages change, so an open thread reloads. */
    private val _revision = MutableStateFlow(0L)
    val revision: StateFlow<Long> = _revision

    private var sync: SyncClient? = null
    private var bb: BlueBubblesClient? = null
    private var stream: StreamClient? = null
    private var bbChats: List<BBChat> = emptyList()

    init {
        // Show cached content immediately, before any network work.
        _chats.value = db.chats()
        scope.launch { outboxLoop() }
    }

    // ---- configuration ----------------------------------------------------

    fun configure(config: TnConfig) {
        stream?.close(); stream = null
        sync = if (config.hasSync) SyncClient(config.syncUrl, config.syncSecret, config.syncToken) else null
        bb = if (config.hasBB) BlueBubblesClient(config.bbUrl, config.bbPassword) else null
        _net.value = _net.value.copy(
            smsConfigured = config.hasSync,
            bbConfigured = config.hasBB,
        )
        Log.i(TAG, "configure: sync=${config.hasSync} bb=${config.hasBB}")

        if (!config.isConfigured) {
            _status.value = Status.NeedsConfig
            return
        }
        // First run has nothing cached: block the list on a "Syncing…" spinner.
        _status.value = if (db.firstSyncDone) Status.Ready else Status.FirstSync
        scope.launch {
            syncAll(full = !db.firstSyncDone)
            connectStream()
        }
    }

    private suspend fun connectStream() {
        val s = sync ?: return
        s.ensureToken()?.let { ConfigStore.setSyncToken(app, it) }
        val url = s.streamUrl() ?: return
        stream?.close()
        stream = StreamClient(url) { scope.launch { syncSms() ; publishChats() } }.also { it.connect() }
    }

    // ---- status -----------------------------------------------------------

    private fun onlineNow(): Boolean {
        val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return true
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    // ---- sync -------------------------------------------------------------

    /** Incremental sync of both backends (used by launch, stream, pull-to-refresh). */
    fun refresh() {
        if (sync == null && bb == null) {
            _status.value = Status.NeedsConfig
            return
        }
        scope.launch { syncAll(full = false) }
    }

    private suspend fun syncAll(full: Boolean) {
        if (syncMutex.isLocked) return
        syncMutex.withLock {
            _syncing.value = true
            _net.value = _net.value.copy(online = onlineNow())
            try {
                // Hard ceiling: a hung request must never leave "Syncing…" up
                // indefinitely (the per-call OkHttp timeouts still apply).
                withTimeoutOrNull(120_000) {
                    syncSms()
                    syncIMessage(allChats = full || !db.firstSyncDone)
                }
                publishChats()
                if (!db.firstSyncDone) db.firstSyncDone = true
                _status.value = Status.Ready
                // Pick up contacts added/edited since the chat rows were stored.
                Contacts.invalidate()
                refreshContactNames()
            } finally {
                _syncing.value = false
            }
        }
    }

    /** Pulls the SMS server's delta, paging until the cursor stops advancing. */
    private suspend fun syncSms() {
        val s = sync ?: return
        var ok = false
        try {
            var guard = 0
            while (guard++ < 50) {
                val cursor = db.syncCursor
                val d = s.delta(cursor) ?: break
                ok = true
                if (d.messages.isEmpty() && d.deletions.isEmpty()) {
                    if (d.cursor > cursor) db.syncCursor = d.cursor
                    break
                }
                // Group by conversation and store.
                val byChat = d.messages.filter { it.conversationId.isNotBlank() }
                    .groupBy { it.conversationId }
                for ((convId, msgs) in byChat) {
                    val ui = msgs.map { m ->
                        UiMessage(
                            id = m.id,
                            text = m.body,
                            fromMe = m.fromMe,
                            timestamp = m.ts,
                            service = Service.SMS,
                            imageUrl = m.attachments.firstOrNull { it.mime.startsWith("image/") }
                                ?.let { s.mediaUrl(it.sha256) },
                        )
                    }
                    db.upsertMessages(ui, convId)
                    val addr = msgs.lastOrNull { it.address.isNotBlank() }?.address ?: convId
                    val newest = msgs.maxByOrNull { it.ts }
                    upsertSmsChat(convId, addr, newest?.body.orEmpty(), newest?.ts ?: 0L,
                        hasImage = newest?.attachments?.isNotEmpty() == true)
                }
                for (del in d.deletions) del.messageId?.let { db.deleteMessage(it) }
                d.conversations.forEach { conv ->
                    if (conv.id.isNotBlank()) markUnread(conv.id, conv.unread)
                }
                if (d.cursor <= cursor) break
                db.syncCursor = d.cursor
                s.token?.let { ConfigStore.setSyncToken(app, it) }
                if (d.messages.size < 2000) break
            }
        } catch (e: Exception) {
            Log.w(TAG, "SMS sync failed: ${e.javaClass.simpleName}: ${e.message}")
        }
        _net.value = _net.value.copy(smsOk = ok || !_net.value.smsConfigured)
    }

    /**
     * iMessage has no server-side delta, so we list chats and fetch each chat's
     * messages newer than what we already stored. First run walks every chat;
     * later runs still walk them (cheap: each request returns only new messages).
     */
    private suspend fun syncIMessage(allChats: Boolean) {
        val b = bb ?: return
        var ok = false
        try {
            val list = b.chats()
            if (list != null) {
                ok = true
                bbChats = list
                for (chat in list) {
                    val isGroup = (chat.style == 43) || chat.participants.size > 1
                    val participant = chat.chatIdentifier ?: chat.participants.firstOrNull()?.address ?: continue
                    val key = if (isGroup) chat.guid else Addr.normalize(participant)
                    upsertBbChat(chat, key, participant, isGroup)

                    val after = maxOf(db.bbCursor(chat.guid), newestBbTs(key))
                    val msgs = try {
                        b.messages(chat.guid, afterMs = after)
                    } catch (e: Exception) {
                        Log.w(TAG, "BB messages(${chat.guid}) failed: ${e.message}")
                        null
                    } ?: continue
                    if (msgs.isEmpty()) continue
                    val ui = msgs.map { m ->
                        UiMessage(
                            id = m.guid,
                            text = m.text.orEmpty(),
                            fromMe = m.isFromMe,
                            timestamp = m.dateCreated ?: 0L,
                            service = Service.IMESSAGE,
                            imageUrl = m.attachments.firstOrNull { (it.mimeType ?: "").startsWith("image/") }
                                ?.let { b.attachmentUrl(it.guid) },
                        )
                    }.filter { it.text.isNotBlank() || it.imageUrl != null }
                    db.upsertMessages(ui, key)
                    msgs.mapNotNull { it.dateCreated }.maxOrNull()?.let { db.setBbCursor(chat.guid, it) }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "iMessage sync failed: ${e.javaClass.simpleName}: ${e.message}")
        }
        _net.value = _net.value.copy(bbOk = ok || !_net.value.bbConfigured)
    }

    private fun newestBbTs(chatKey: String): Long =
        db.messages(chatKey).filter { it.service == Service.IMESSAGE }.maxOfOrNull { it.timestamp } ?: 0L

    // ---- chat rows --------------------------------------------------------

    private fun upsertSmsChat(convId: String, address: String, snippet: String, ts: Long, hasImage: Boolean) {
        val existing = db.chats().firstOrNull { it.key == convId }
        val newer = ts >= (existing?.timestamp ?: 0L)
        db.upsertChats(
            listOf(
                UiChat(
                    key = convId,
                    title = existing?.title?.takeIf { it.isNotBlank() && it != address }
                        ?: Contacts.displayName(app, address),
                    snippet = if (newer) snippet.ifBlank { if (hasImage) "📷 Photo" else "" }
                    else existing?.snippet.orEmpty(),
                    timestamp = maxOf(ts, existing?.timestamp ?: 0L),
                    unread = existing?.unread ?: false,
                    services = setOfNotNull(Service.SMS, existing?.bbChatGuid?.let { Service.IMESSAGE }),
                    smsAddress = address,
                    bbChatGuid = existing?.bbChatGuid,
                    isGroup = existing?.isGroup ?: false,
                    lastService = if (newer) Service.SMS else existing?.lastService,
                ),
            ),
        )
    }

    private fun upsertBbChat(chat: BBChat, key: String, participant: String, isGroup: Boolean) {
        val existing = db.chats().firstOrNull { it.key == key }
        val lm = chat.lastMessage
        val ts = lm?.dateCreated ?: 0L
        val snippet = lm?.text?.takeIf { it.isNotBlank() }
            ?: if (lm?.attachments?.isNotEmpty() == true) "📷 Photo" else ""
        val newer = ts >= (existing?.timestamp ?: 0L)
        val title = chat.displayName?.takeIf { it.isNotBlank() }
            ?: existing?.title?.takeIf { it.isNotBlank() }
            ?: if (isGroup) "Group" else Contacts.displayName(app, participant)
        db.upsertChats(
            listOf(
                UiChat(
                    key = key,
                    title = title,
                    snippet = if (newer) snippet else existing?.snippet.orEmpty(),
                    timestamp = maxOf(ts, existing?.timestamp ?: 0L),
                    unread = existing?.unread ?: false,
                    services = setOfNotNull(Service.IMESSAGE, existing?.smsAddress?.let { Service.SMS }),
                    smsAddress = existing?.smsAddress,
                    bbChatGuid = chat.guid,
                    isGroup = isGroup,
                    lastService = if (newer) Service.IMESSAGE else existing?.lastService,
                ),
            ),
        )
    }

    private fun markUnread(convId: String, unread: Boolean) {
        val existing = db.chats().firstOrNull { it.key == convId } ?: return
        db.upsertChats(listOf(existing.copy(unread = unread)))
    }

    private fun publishChats() {
        _chats.value = db.chats()
            .filter { it.key.isNotBlank() }
            .distinctBy { it.key }
            .sortedByDescending { it.timestamp }
        _revision.value = _revision.value + 1
    }

    // ---- threads ----------------------------------------------------------

    /** Cached thread contents plus anything still queued for sending. */
    fun thread(chat: UiChat): List<UiMessage> {
        val stored = db.messages(chat.key)
        val queued = db.pendingOutboxFor(chat.key).map {
            UiMessage(
                id = "outbox-${it.id}",
                text = it.body,
                fromMe = true,
                timestamp = it.createdAt,
                service = it.service,
                pending = true,
            )
        }
        return (stored + queued).distinctBy { it.id }.sortedBy { it.timestamp }
    }

    // ---- sending ----------------------------------------------------------

    /**
     * Queues a message and tries to send immediately. Always returns after
     * queueing, so composing works offline; the outbox retries until it lands.
     */
    fun send(chat: UiChat, service: Service, text: String) {
        val target = when (service) {
            Service.SMS -> chat.smsAddress
            Service.IMESSAGE -> chat.bbChatGuid
        } ?: return
        db.enqueueOutbox(chat.key, service, target, text)
        _revision.value = _revision.value + 1
        scope.launch { flushOutbox() }
    }

    private suspend fun outboxLoop() {
        while (scope.isActive) {
            delay(15_000)
            if (db.pendingOutbox().isNotEmpty()) flushOutbox()
        }
    }

    private suspend fun flushOutbox() {
        val pending = db.pendingOutbox()
        if (pending.isEmpty()) return
        _net.value = _net.value.copy(online = onlineNow())
        if (!_net.value.online) return

        for (item in pending) {
            val sent = try {
                when (item.service) {
                    Service.SMS -> sync?.send(item.target, item.body) ?: false
                    Service.IMESSAGE -> bb?.sendText(item.target, item.body) ?: false
                }
            } catch (e: Exception) {
                Log.w(TAG, "outbox send failed: ${e.message}")
                false
            }
            if (sent) db.removeOutbox(item.id) else db.bumpOutboxAttempts(item.id)
        }
        _revision.value = _revision.value + 1
        // Pick up the server's copy of what we just sent.
        syncAll(full = false)
    }

    // ---- misc -------------------------------------------------------------

    /** Header needed to load an authenticated sync-server media URL.
     *  (BlueBubbles URLs carry ?password= and need no header.) */
    fun syncAuthHeader(url: String): Pair<String, String>? {
        val bearer = sync?.bearer() ?: return null
        return if (url.contains("/media/")) "Authorization" to bearer else null
    }

    /** Storage this app occupies on the watch: installed APK + all app data
     *  (database, image cache, prefs). Mirrors what Android's app-info screen
     *  reports, without needing the usage-stats permission. */
    private fun storageBytes(): Long {
        fun sizeOf(file: File): Long = when {
            !file.exists() -> 0L
            file.isFile -> file.length()
            else -> file.listFiles()?.sumOf { sizeOf(it) } ?: 0L
        }
        val data = runCatching { sizeOf(app.dataDir) }.getOrDefault(0L)
        val apk = runCatching {
            val info = app.applicationInfo
            var total = File(info.sourceDir).length()
            info.splitSourceDirs?.forEach { total += File(it).length() }
            total
        }.getOrDefault(0L)
        return data + apk
    }

    /** Status snapshot for the phone's "Watch App Client" screen. */
    fun statusSnapshot(): Map<String, Any> {
        val (chatCount, messageCount, outboxCount) = db.counts()
        val n = _net.value
        return mapOf(
            "storageBytes" to storageBytes(),
            "avatars" to AvatarStore.count(app),
            "online" to n.online,
            "smsConfigured" to n.smsConfigured,
            "smsOk" to n.smsOk,
            "bbConfigured" to n.bbConfigured,
            "bbOk" to n.bbOk,
            "chats" to chatCount,
            "messages" to messageCount,
            "queued" to outboxCount,
            "firstSyncDone" to db.firstSyncDone,
            "syncing" to _syncing.value,
        )
    }

    /**
     * Re-resolve contact names for chats already cached. Photos are looked up
     * live by the UI, so rebuilding the contact index is enough for those; stored
     * titles need this pass (e.g. after the contacts permission is granted).
     */
    fun refreshContactNames() {
        scope.launch {
            val updates = db.chats().mapNotNull { chat ->
                if (chat.isGroup) return@mapNotNull null
                val address = chat.smsAddress ?: chat.key
                val name = Contacts.displayName(app, address)
                // displayName echoes the address back when there's no match.
                if (name != address && name != chat.title) chat.copy(title = name) else null
            }
            if (updates.isNotEmpty()) db.upsertChats(updates)
            publishChats()
        }
    }

    /** Wipes the cache and re-syncs everything (phone-initiated "Re-sync"). */
    fun fullResync() {
        scope.launch {
            db.wipe()
            AvatarStore.clear(app)   // photos re-arrive from the phone
            _chats.value = emptyList()
            _status.value = Status.FirstSync
            syncAll(full = true)
        }
    }
}
