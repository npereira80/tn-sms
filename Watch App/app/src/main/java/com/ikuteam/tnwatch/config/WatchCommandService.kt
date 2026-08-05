package com.ikuteam.tnwatch.config

import android.util.Log
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import com.ikuteam.tnwatch.TnWatchApp
import org.json.JSONObject

/**
 * Serves the phone's "Watch App Client" screen over the Data Layer (Bluetooth):
 *
 *   /tnwatch/status   → replies on /tnwatch/status-reply with a JSON snapshot
 *   /tnwatch/resync   → wipes the local cache and re-syncs everything
 */
class WatchCommandService : WearableListenerService() {

    override fun onMessageReceived(event: MessageEvent) {
        when (event.path) {
            PATH_STATUS -> replyStatus(event.sourceNodeId)
            PATH_RESYNC -> {
                Log.i(TAG, "full re-sync requested by phone")
                TnWatchApp.repo(this).fullResync()
                replyStatus(event.sourceNodeId)
            }
        }
    }

    private fun replyStatus(nodeId: String) {
        val repo = TnWatchApp.repo(this)
        val config = ConfigStore.state.value
        val json = JSONObject().apply {
            for ((k, v) in repo.statusSnapshot()) put(k, v)
            put("syncUrl", config.syncUrl)
            put("bbUrl", config.bbUrl)
            put("appVersion", "1.0")
        }.toString()
        Wearable.getMessageClient(this)
            .sendMessage(nodeId, PATH_STATUS_REPLY, json.toByteArray())
            .addOnFailureListener { Log.w(TAG, "status reply failed: ${it.message}") }
    }

    companion object {
        private const val TAG = "TnWatchCmd"
        const val PATH_STATUS = "/tnwatch/status"
        const val PATH_STATUS_REPLY = "/tnwatch/status-reply"
        const val PATH_RESYNC = "/tnwatch/resync"
    }
}
