package com.ikuteam.tnwatch.net

import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.UUID

/**
 * Client for the BlueBubbles server (iMessage). REST, authed with a ?password=
 * query param. Lists chats, fetches a chat's messages, and sends text over the
 * private API (matching the phone app's default send path).
 *
 * Requests go through [Http.exec], so they fall back to running on the phone over
 * Bluetooth when the watch has no network of its own.
 */
class BlueBubblesClient(
    private val baseUrl: String,
    private val password: String,
) {
    private val jsonMedia = "application/json".toMediaType()

    private fun url(path: String): String =
        (baseUrl.trimEnd('/') + "/api/v1/" + path.trimStart('/')).toHttpUrl()
            .newBuilder()
            .addQueryParameter("password", password)
            .build()
            .toString()

    suspend fun ping(): Boolean = chats(limit = 1) != null

    suspend fun chats(limit: Int = 500): List<BBChat>? {
        val body = buildJsonObject {
            put("limit", limit)
            put("offset", 0)
            putJsonArray("with") { add("participants"); add("lastMessage") }
            put("sort", "lastmessage")
        }.toString().toRequestBody(jsonMedia)
        val resp = Http.exec(Request.Builder().url(url("chat/query")).post(body).build())
        if (resp == null || !resp.isSuccessful) return null
        return runCatching {
            Http.json.decodeFromString(BBChatQueryResponse.serializer(), resp.body).data
        }.getOrNull()
    }

    /** Messages for a chat, newest history first then sorted ascending. */
    suspend fun messages(chatGuid: String, afterMs: Long = 0, limit: Int = 100): List<BBMessage>? {
        val body = buildJsonObject {
            put("chatGuid", chatGuid)
            put("limit", limit)
            putJsonArray("with") { add("handle"); add("attachment") }
            put("sort", "DESC")
            if (afterMs > 0) put("after", afterMs)
        }.toString().toRequestBody(jsonMedia)
        val resp = Http.exec(Request.Builder().url(url("message/query")).post(body).build())
        if (resp == null || !resp.isSuccessful) return null
        return runCatching {
            Http.json.decodeFromString(BBMessageQueryResponse.serializer(), resp.body)
                .data.sortedBy { it.dateCreated ?: 0 }
        }.getOrNull()
    }

    /** Send an iMessage into an existing chat. */
    suspend fun sendText(chatGuid: String, message: String): Boolean {
        val body = buildJsonObject {
            put("chatGuid", chatGuid)
            put("tempGuid", "tnwatch-" + UUID.randomUUID())
            put("message", message)
            put("method", "private-api")
        }.toString().toRequestBody(jsonMedia)
        val resp = Http.exec(Request.Builder().url(url("message/text")).post(body).build())
        return resp?.isSuccessful == true
    }

    fun attachmentUrl(guid: String): String = url("attachment/$guid/download")
}
