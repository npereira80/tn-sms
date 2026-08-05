package com.ikuteam.tnwatch.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

/**
 * Client for the SMS sync server (SMS/MMS). Mirrors the phone's sms_server_client:
 * register for a bearer token, poll /delta, and relay outbound SMS through /send
 * (the primary phone fulfils it over the radio).
 */
class SyncClient(
    private val baseUrl: String,
    private val secret: String,
    var token: String?,
) {
    private val jsonMedia = "application/json".toMediaType()
    private fun url(path: String) = baseUrl.trimEnd('/') + path

    /** Registers this watch as a Wi-Fi device and returns the bearer token. */
    suspend fun register(label: String = "TN Watch"): String? = withContext(Dispatchers.IO) {
        val body = buildJsonObject {
            put("secret", secret)
            put("label", label)
            put("platform", "android")
        }.toString().toRequestBody(jsonMedia)
        val req = Request.Builder().url(url("/devices/register")).post(body).build()
        Http.client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) return@withContext null
            val parsed = Http.json.decodeFromString(RegisterResponse.serializer(), resp.body!!.string())
            token = parsed.token
            parsed.token
        }
    }

    /** Ensures we have a token, registering on first use. */
    suspend fun ensureToken(): String? {
        if (!token.isNullOrBlank()) return token
        return register()
    }

    suspend fun delta(since: Long): DeltaResponse? = withContext(Dispatchers.IO) {
        val t = ensureToken() ?: return@withContext null
        val req = Request.Builder()
            .url(url("/delta?since=$since"))
            .header("Authorization", "Bearer $t")
            .get().build()
        Http.client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) return@withContext null
            Http.json.decodeFromString(DeltaResponse.serializer(), resp.body!!.string())
        }
    }

    /** Relay an outbound SMS to the primary phone. */
    suspend fun send(to: String, body: String): Boolean = withContext(Dispatchers.IO) {
        val t = ensureToken() ?: return@withContext false
        val payload = buildJsonObject {
            put("to", to)
            put("body", body)
        }.toString().toRequestBody(jsonMedia)
        val req = Request.Builder()
            .url(url("/send"))
            .header("Authorization", "Bearer $t")
            .post(payload).build()
        Http.client.newCall(req).execute().use { it.isSuccessful }
    }

    /** Delete specific messages everywhere (server tombstones + broadcasts). */
    suspend fun deleteMessages(ids: List<String>): Boolean = withContext(Dispatchers.IO) {
        if (ids.isEmpty()) return@withContext false
        val t = ensureToken() ?: return@withContext false
        val payload = buildJsonObject {
            putJsonArray("messageIds") { ids.forEach { add(it) } }
        }.toString().toRequestBody(jsonMedia)
        val req = Request.Builder()
            .url(url("/delete"))
            .header("Authorization", "Bearer $t")
            .post(payload).build()
        Http.client.newCall(req).execute().use { it.isSuccessful }
    }

    /** Delete a whole conversation everywhere. */
    suspend fun deleteConversation(conversationId: String): Boolean = withContext(Dispatchers.IO) {
        if (conversationId.isBlank()) return@withContext false
        val t = ensureToken() ?: return@withContext false
        val payload = buildJsonObject {
            put("conversationId", conversationId)
        }.toString().toRequestBody(jsonMedia)
        val req = Request.Builder()
            .url(url("/delete"))
            .header("Authorization", "Bearer $t")
            .post(payload).build()
        Http.client.newCall(req).execute().use { it.isSuccessful }
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
