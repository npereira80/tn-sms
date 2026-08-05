package com.ikuteam.tnwatch.net

import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Client for the SMS sync server (SMS/MMS). Mirrors the phone's sms_server_client:
 * register for a bearer token, poll /delta, and relay outbound SMS through /send
 * (the primary phone fulfils it over the radio).
 *
 * Every call goes through [Http.exec], which tries the watch's own network and
 * then falls back to running the request on the phone over Bluetooth.
 */
class SyncClient(
    private val baseUrl: String,
    private val secret: String,
    var token: String?,
) {
    private val jsonMedia = "application/json".toMediaType()
    private fun url(path: String) = baseUrl.trimEnd('/') + path

    /** Registers this watch as a Wi-Fi device and returns the bearer token. */
    suspend fun register(label: String = "TN Watch"): String? {
        val body = buildJsonObject {
            put("secret", secret)
            put("label", label)
            put("platform", "android")
        }.toString().toRequestBody(jsonMedia)
        val resp = Http.exec(Request.Builder().url(url("/devices/register")).post(body).build())
        if (resp == null || !resp.isSuccessful) return null
        token = runCatching {
            Http.json.decodeFromString(RegisterResponse.serializer(), resp.body).token
        }.getOrNull()
        return token
    }

    /** Ensures we have a token, registering on first use. */
    suspend fun ensureToken(): String? {
        if (!token.isNullOrBlank()) return token
        return register()
    }

    suspend fun delta(since: Long): DeltaResponse? {
        val t = ensureToken() ?: return null
        val resp = Http.exec(
            Request.Builder()
                .url(url("/delta?since=$since"))
                .header("Authorization", "Bearer $t")
                .get().build(),
        )
        if (resp == null || !resp.isSuccessful) return null
        return runCatching {
            Http.json.decodeFromString(DeltaResponse.serializer(), resp.body)
        }.getOrNull()
    }

    /**
     * Ids + hashes this conversation currently holds server-side, so the caller
     * can drop local copies of messages deleted elsewhere.
     */
    suspend fun conversationKeys(conversationId: String): ConversationKeys? {
        if (conversationId.isBlank()) return null
        val t = ensureToken() ?: return null
        val encoded = java.net.URLEncoder.encode(conversationId, "UTF-8")
        val resp = Http.exec(
            Request.Builder()
                .url(url("/conversation/$encoded/messages"))
                .header("Authorization", "Bearer $t")
                .get().build(),
        )
        if (resp == null || !resp.isSuccessful) return null
        return runCatching {
            Http.json.decodeFromString(ConversationKeys.serializer(), resp.body)
        }.getOrNull()
    }

    /** Relay an outbound SMS to the primary phone. */
    suspend fun send(to: String, body: String): Boolean {
        val t = ensureToken() ?: return false
        val payload = buildJsonObject {
            put("to", to)
            put("body", body)
        }.toString().toRequestBody(jsonMedia)
        val resp = Http.exec(
            Request.Builder()
                .url(url("/send"))
                .header("Authorization", "Bearer $t")
                .post(payload).build(),
        )
        return resp?.isSuccessful == true
    }

    /** Delete specific messages everywhere (server tombstones + broadcasts). */
    suspend fun deleteMessages(ids: List<String>): Boolean {
        if (ids.isEmpty()) return false
        val t = ensureToken() ?: return false
        val payload = buildJsonObject {
            putJsonArray("messageIds") { ids.forEach { add(it) } }
        }.toString().toRequestBody(jsonMedia)
        val resp = Http.exec(
            Request.Builder()
                .url(url("/delete"))
                .header("Authorization", "Bearer $t")
                .post(payload).build(),
        )
        return resp?.isSuccessful == true
    }

    /** Delete a whole conversation everywhere. */
    suspend fun deleteConversation(conversationId: String): Boolean {
        if (conversationId.isBlank()) return false
        val t = ensureToken() ?: return false
        val payload = buildJsonObject {
            put("conversationId", conversationId)
        }.toString().toRequestBody(jsonMedia)
        val resp = Http.exec(
            Request.Builder()
                .url(url("/delete"))
                .header("Authorization", "Bearer $t")
                .post(payload).build(),
        )
        return resp?.isSuccessful == true
    }

    fun mediaUrl(sha256: String): String = url("/media/$sha256")

    fun streamUrl(): String? {
        val t = token ?: return null
        val ws = baseUrl.trimEnd('/')
            .replaceFirst("https://", "wss://")
            .replaceFirst("http://", "ws://")
        return "$ws/stream?token=$t"
    }

    fun bearer(): String? = token?.let { "Bearer $it" }
}
