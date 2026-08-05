package com.ikuteam.tnwatch.data

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/**
 * Local message store, so threads are readable offline and each launch only has
 * to fetch what's new. Deliberately hand-rolled SQLite (no Room/codegen) to keep
 * the watch module's build simple.
 *
 * Cursors live in `kv`:
 *   sync_cursor          — SMS sync-server /delta cursor
 *   bb_cursor:<chatGuid> — newest iMessage timestamp seen for that chat
 *   first_sync_done      — "1" once the initial full sync completed
 */
class Db(context: Context) : SQLiteOpenHelper(context, "tnwatch.db", null, 3) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE message (
                id TEXT PRIMARY KEY,
                chat_key TEXT NOT NULL,
                service TEXT NOT NULL,
                body TEXT NOT NULL DEFAULT '',
                from_me INTEGER NOT NULL DEFAULT 0,
                ts INTEGER NOT NULL DEFAULT 0,
                image_url TEXT,
                content_hash TEXT
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE INDEX idx_message_chat_ts ON message(chat_key, ts)")
        db.execSQL("CREATE INDEX idx_message_hash ON message(content_hash)")
        db.execSQL(
            """
            CREATE TABLE chat (
                key TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                snippet TEXT NOT NULL DEFAULT '',
                ts INTEGER NOT NULL DEFAULT 0,
                unread INTEGER NOT NULL DEFAULT 0,
                sms_address TEXT,
                bb_guid TEXT,
                is_group INTEGER NOT NULL DEFAULT 0,
                last_service TEXT
            )
            """.trimIndent(),
        )
        db.execSQL(
            """
            CREATE TABLE outbox (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_key TEXT NOT NULL,
                service TEXT NOT NULL,
                target TEXT NOT NULL,
                body TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Additive migrations only, so an upgrade never forces a full re-sync.
        if (oldVersion < 2) {
            runCatching { db.execSQL("ALTER TABLE chat ADD COLUMN last_service TEXT") }
        }
        if (oldVersion < 3) {
            runCatching { db.execSQL("ALTER TABLE message ADD COLUMN content_hash TEXT") }
            runCatching { db.execSQL("CREATE INDEX idx_message_hash ON message(content_hash)") }
        }
    }

    // ---- kv ---------------------------------------------------------------

    fun kvGet(key: String): String? =
        readableDatabase.query("kv", arrayOf("v"), "k = ?", arrayOf(key), null, null, null)
            .use { if (it.moveToFirst()) it.getString(0) else null }

    fun kvSet(key: String, value: String) {
        writableDatabase.insertWithOnConflict(
            "kv", null,
            ContentValues().apply { put("k", key); put("v", value) },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    var syncCursor: Long
        get() = kvGet("sync_cursor")?.toLongOrNull() ?: 0L
        set(value) = kvSet("sync_cursor", value.toString())

    fun bbCursor(chatGuid: String): Long = kvGet("bb_cursor:$chatGuid")?.toLongOrNull() ?: 0L
    fun setBbCursor(chatGuid: String, ts: Long) = kvSet("bb_cursor:$chatGuid", ts.toString())

    var firstSyncDone: Boolean
        get() = kvGet("first_sync_done") == "1"
        set(value) = kvSet("first_sync_done", if (value) "1" else "0")

    // ---- messages ---------------------------------------------------------

    fun upsertMessages(messages: List<UiMessage>, chatKey: String) {
        if (messages.isEmpty()) return
        val db = writableDatabase
        db.beginTransaction()
        try {
            for (m in messages) {
                db.insertWithOnConflict(
                    "message", null,
                    ContentValues().apply {
                        put("id", m.id)
                        put("chat_key", chatKey)
                        put("service", m.service.name)
                        put("body", m.text)
                        put("from_me", if (m.fromMe) 1 else 0)
                        put("ts", m.timestamp)
                        put("image_url", m.imageUrl)
                        put("content_hash", m.contentHash)
                    },
                    SQLiteDatabase.CONFLICT_REPLACE,
                )
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    fun messages(chatKey: String): List<UiMessage> =
        readableDatabase.query(
            "message",
            arrayOf("id", "service", "body", "from_me", "ts", "image_url", "content_hash"),
            "chat_key = ?", arrayOf(chatKey), null, null, "ts ASC",
        ).use { c ->
            val out = ArrayList<UiMessage>(c.count)
            while (c.moveToNext()) {
                out += UiMessage(
                    id = c.getString(0),
                    service = runCatching { Service.valueOf(c.getString(1)) }.getOrDefault(Service.SMS),
                    text = c.getString(2),
                    fromMe = c.getInt(3) == 1,
                    timestamp = c.getLong(4),
                    imageUrl = if (c.isNull(5)) null else c.getString(5),
                    contentHash = if (c.isNull(6)) null else c.getString(6),
                )
            }
            out
        }

    /** Removes a message by server id. Returns rows affected. */
    fun deleteMessage(id: String): Int =
        writableDatabase.delete("message", "id = ?", arrayOf(id))

    /** Removes a message by cross-device content hash. Returns rows affected.
     *  Needed when a tombstone's server id doesn't match our cached copy. */
    fun deleteMessageByHash(hash: String): Int =
        writableDatabase.delete("message", "content_hash = ?", arrayOf(hash))

    /** Removes a whole thread: its messages, the chat row, and any queued sends. */
    fun deleteChat(key: String) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.delete("message", "chat_key = ?", arrayOf(key))
            db.delete("chat", "key = ?", arrayOf(key))
            db.delete("outbox", "chat_key = ?", arrayOf(key))
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /** Newest stored timestamp for a chat, used as an incremental fetch cursor. */
    fun newestTs(chatKey: String): Long =
        readableDatabase.rawQuery(
            "SELECT MAX(ts) FROM message WHERE chat_key = ?", arrayOf(chatKey),
        ).use { if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else 0L }

    /** As [newestTs], restricted to one service. Cheap: MAX() in SQL rather than
     *  loading a thread's messages into memory. */
    fun newestTs(chatKey: String, service: Service): Long =
        readableDatabase.rawQuery(
            "SELECT MAX(ts) FROM message WHERE chat_key = ? AND service = ?",
            arrayOf(chatKey, service.name),
        ).use { if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else 0L }

    // ---- chats ------------------------------------------------------------

    fun upsertChats(chats: List<UiChat>) {
        if (chats.isEmpty()) return
        val db = writableDatabase
        db.beginTransaction()
        try {
            for (c in chats) {
                db.insertWithOnConflict(
                    "chat", null,
                    ContentValues().apply {
                        put("key", c.key)
                        put("title", c.title)
                        put("snippet", c.snippet)
                        put("ts", c.timestamp)
                        put("unread", if (c.unread) 1 else 0)
                        put("sms_address", c.smsAddress)
                        put("bb_guid", c.bbChatGuid)
                        put("is_group", if (c.isGroup) 1 else 0)
                        put("last_service", c.lastService?.name)
                    },
                    SQLiteDatabase.CONFLICT_REPLACE,
                )
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /** Single chat row. Used on hot paths instead of scanning [chats]. */
    fun chat(key: String): UiChat? =
        readableDatabase.query(
            "chat",
            arrayOf("key", "title", "snippet", "ts", "unread", "sms_address", "bb_guid", "is_group", "last_service"),
            "key = ?", arrayOf(key), null, null, null,
        ).use { c -> if (c.moveToFirst()) c.toUiChat() else null }

    fun chats(): List<UiChat> =
        readableDatabase.query(
            "chat",
            arrayOf("key", "title", "snippet", "ts", "unread", "sms_address", "bb_guid", "is_group", "last_service"),
            null, null, null, null, "ts DESC",
        ).use { c ->
            val out = ArrayList<UiChat>(c.count)
            while (c.moveToNext()) out += c.toUiChat() ?: continue
            out
        }

    /** Maps the current row of a chat query (column order as above) to [UiChat]. */
    private fun android.database.Cursor.toUiChat(): UiChat? {
        val smsAddress = if (isNull(5)) null else getString(5)
        val bbGuid = if (isNull(6)) null else getString(6)
        val services = buildSet {
            if (smsAddress != null) add(Service.SMS)
            if (bbGuid != null) add(Service.IMESSAGE)
        }
        if (services.isEmpty()) return null
        return UiChat(
            key = getString(0),
            title = getString(1),
            snippet = getString(2),
            timestamp = getLong(3),
            unread = getInt(4) == 1,
            services = services,
            smsAddress = smsAddress,
            bbChatGuid = bbGuid,
            isGroup = getInt(7) == 1,
            lastService = if (isNull(8)) null
            else runCatching { Service.valueOf(getString(8)) }.getOrNull(),
        )
    }

    // ---- outbox (offline send queue) --------------------------------------

    fun enqueueOutbox(chatKey: String, service: Service, target: String, body: String): Long =
        writableDatabase.insert(
            "outbox", null,
            ContentValues().apply {
                put("chat_key", chatKey)
                put("service", service.name)
                put("target", target)
                put("body", body)
                put("created_at", System.currentTimeMillis())
            },
        )

    fun pendingOutbox(): List<OutboxItem> =
        readableDatabase.query(
            "outbox",
            arrayOf("id", "chat_key", "service", "target", "body", "created_at"),
            null, null, null, null, "created_at ASC",
        ).use { c ->
            val out = ArrayList<OutboxItem>(c.count)
            while (c.moveToNext()) {
                out += OutboxItem(
                    id = c.getLong(0),
                    chatKey = c.getString(1),
                    service = runCatching { Service.valueOf(c.getString(2)) }.getOrDefault(Service.SMS),
                    target = c.getString(3),
                    body = c.getString(4),
                    createdAt = c.getLong(5),
                )
            }
            out
        }

    fun pendingOutboxFor(chatKey: String): List<OutboxItem> =
        pendingOutbox().filter { it.chatKey == chatKey }

    fun removeOutbox(id: Long) {
        writableDatabase.delete("outbox", "id = ?", arrayOf(id.toString()))
    }

    fun bumpOutboxAttempts(id: Long) {
        writableDatabase.execSQL("UPDATE outbox SET attempts = attempts + 1 WHERE id = ?", arrayOf(id))
    }

    fun counts(): Triple<Int, Int, Int> {
        fun count(table: String) = readableDatabase.rawQuery("SELECT COUNT(*) FROM $table", null)
            .use { if (it.moveToFirst()) it.getInt(0) else 0 }
        return Triple(count("chat"), count("message"), count("outbox"))
    }

    /** Full reset (used by the phone's "Re-sync" action). */
    fun wipe() {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.delete("message", null, null)
            db.delete("chat", null, null)
            db.delete("kv", null, null)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }
}

data class OutboxItem(
    val id: Long,
    val chatKey: String,
    val service: Service,
    val target: String,
    val body: String,
    val createdAt: Long,
)
