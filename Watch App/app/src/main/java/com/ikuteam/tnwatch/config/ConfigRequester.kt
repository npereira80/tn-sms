package com.ikuteam.tnwatch.config

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.tasks.await

/**
 * Asks the phone app to (re)send the config. On launch the watch sends a
 * "/tnwatch/request-config" message to connected nodes; the phone app answers
 * by putting the config DataItem, which [ConfigListenerService] then stores.
 */
object ConfigRequester {
    private const val TAG = "TnWatchConfig"
    private const val REQUEST_PATH = "/tnwatch/request-config"
    private const val PHONE_CAPABILITY = "tnwatch_config_provider"

    suspend fun requestFromPhone(context: Context) {
        try {
            val messageClient = Wearable.getMessageClient(context)
            val capabilityClient = Wearable.getCapabilityClient(context)

            // Prefer a node that advertises the provider capability; fall back to
            // any connected node.
            val capable = runCatching {
                capabilityClient
                    .getCapability(PHONE_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
                    .await().nodes
            }.getOrNull().orEmpty()
            val nodes = capable.ifEmpty { Wearable.getNodeClient(context).connectedNodes.await() }

            for (node in nodes) {
                runCatching { messageClient.sendMessage(node.id, REQUEST_PATH, ByteArray(0)).await() }
                    .onFailure { Log.w(TAG, "request-config to ${node.id} failed: ${it.message}") }
            }
        } catch (e: Exception) {
            Log.w(TAG, "requestFromPhone failed: ${e.message}")
        }
    }
}
