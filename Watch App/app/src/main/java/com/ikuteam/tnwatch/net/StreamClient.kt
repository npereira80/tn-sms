package com.ikuteam.tnwatch.net

import android.util.Log
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/**
 * Thin wrapper over the sync server's /stream WebSocket. We don't parse every
 * event type here — any inbound frame (new message, read, delete, send status)
 * simply triggers [onActivity], which prompts the repository to pull a fresh
 * /delta. That keeps SMS effectively live without duplicating the event schema.
 */
class StreamClient(
    private val url: String,
    private val onActivity: () -> Unit,
) {
    private var ws: WebSocket? = null
    private var closed = false

    fun connect() {
        closed = false
        open()
    }

    private fun open() {
        if (closed) return
        val req = Request.Builder().url(url).build()
        ws = Http.client.newWebSocket(req, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                onActivity()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w(TAG, "stream failure: ${t.message}")
                scheduleReconnect()
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                scheduleReconnect()
            }
        })
    }

    private fun scheduleReconnect() {
        if (closed) return
        ws = null
        // Simple fixed backoff; the watch reconnects when it next has Wi-Fi.
        Thread {
            Thread.sleep(4000)
            open()
        }.start()
    }

    fun close() {
        closed = true
        ws?.close(1000, "bye")
        ws = null
    }

    companion object {
        private const val TAG = "TnWatchStream"
    }
}
