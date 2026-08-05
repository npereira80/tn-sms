package com.ikuteam.tnwatch.net

import android.util.Base64
import android.util.Log
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Runs an HTTP request on the phone instead of the watch.
 *
 * With no Wi-Fi, a Wear watch does not reliably get an internet route of its own
 * — which is why other watch apps (WhatsApp included) work as *companions*,
 * talking to the phone app over Bluetooth rather than to their servers directly.
 * This is that path: the watch sends the request over the Data Layer, the phone
 * performs it, and the response comes back as an Asset (streamed, so /delta-sized
 * payloads are fine, unlike the ~100KB cap on messages).
 */
object Relay {
    private const val TAG = "TnWatchRelay"
    const val REQUEST_PATH = "/tnwatch/http"
    const val REPLY_PREFIX = "/tnwatch/http-reply/"

    private val pending = ConcurrentHashMap<String, CompletableDeferred<Pair<Int, ByteArray>>>()

    /** Called by [com.ikuteam.tnwatch.config.RelayReplyService] when a reply lands. */
    fun complete(id: String, code: Int, body: ByteArray) {
        pending.remove(id)?.complete(code to body)
    }

    /** Text response variant of [executeRaw]. */
    suspend fun execute(
        method: String,
        url: String,
        headers: Map<String, String>,
        body: ByteArray?,
        contentType: String?,
    ): RawResponse? {
        val (code, bytes) = executeRaw(method, url, headers, body, contentType) ?: return null
        return RawResponse(code, String(bytes))
    }

    /**
     * Performs [method] [url] on the phone and returns the raw bytes, so binary
     * payloads (images) survive intact. Null when the phone can't be reached.
     */
    suspend fun executeRaw(
        method: String,
        url: String,
        headers: Map<String, String>,
        body: ByteArray?,
        contentType: String?,
    ): Pair<Int, ByteArray>? {
        val context = Http.appContext ?: return null
        val id = UUID.randomUUID().toString()
        val deferred = CompletableDeferred<Pair<Int, ByteArray>>()
        pending[id] = deferred
        try {
            val headerJson = JSONObject().apply {
                for ((name, value) in headers) put(name, value)
            }
            val payload = JSONObject().apply {
                put("id", id)
                put("method", method)
                put("url", url)
                put("headers", headerJson)
                if (contentType != null) put("contentType", contentType)
                if (body != null) put("body", Base64.encodeToString(body, Base64.NO_WRAP))
            }.toString().toByteArray()

            val nodes = runCatching {
                Wearable.getNodeClient(context).connectedNodes.await()
            }.getOrNull().orEmpty()
            if (nodes.isEmpty()) return null

            var sent = false
            for (node in nodes) {
                runCatching {
                    Wearable.getMessageClient(context)
                        .sendMessage(node.id, REQUEST_PATH, payload).await()
                    sent = true
                }
            }
            if (!sent) return null

            return withTimeoutOrNull(45_000) { deferred.await() }
                .also { if (it == null) Log.w(TAG, "relay timed out: $method $url") }
        } catch (e: Exception) {
            Log.w(TAG, "relay failed: ${e.message}")
            return null
        } finally {
            pending.remove(id)
        }
    }
}

/** Minimal HTTP result, whether it came from the watch or via the phone. */
data class RawResponse(val code: Int, val body: String) {
    val isSuccessful: Boolean get() = code in 200..299
}
