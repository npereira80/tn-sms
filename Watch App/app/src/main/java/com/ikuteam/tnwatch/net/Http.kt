package com.ikuteam.tnwatch.net

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import okio.Buffer
import java.util.concurrent.TimeUnit

/** Shared OkHttp client + lenient JSON for all network code. */
object Http {
    /** Set once from the Application; needed to reach the phone for relaying. */
    @Volatile
    var appContext: Context? = null

    val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }

    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .callTimeout(40, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    /**
     * Runs [request] from the watch, falling back to the phone over Bluetooth.
     *
     * Off Wi-Fi the watch usually has no usable internet route of its own, so a
     * direct call fails fast; the phone then performs it for us (see [Relay]).
     * Returns null when neither path worked.
     */
    suspend fun exec(request: Request): RawResponse? {
        direct(request)?.let { return it }

        // Direct call failed: hand it to the phone.
        val headers = buildMap {
            for (i in 0 until request.headers.size) put(request.headers.name(i), request.headers.value(i))
        }
        val bodyBytes = request.body?.let { body ->
            Buffer().also { body.writeTo(it) }.readByteArray()
        }
        return Relay.execute(
            method = request.method,
            url = request.url.toString(),
            headers = headers,
            body = bodyBytes,
            contentType = request.body?.contentType()?.toString(),
        )
    }

    private suspend fun direct(request: Request): RawResponse? = withContext(Dispatchers.IO) {
        try {
            client.newCall(request).execute().use { resp ->
                RawResponse(resp.code, resp.body?.string().orEmpty())
            }
        } catch (e: Exception) {
            null // no route from the watch itself — caller falls back to the phone
        }
    }
}
