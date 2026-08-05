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
    private const val AVATARS_PATH = "/tnwatch/request-avatars"
    private const val PHONE_CAPABILITY = "tnwatch_config_provider"

    /** Ask the phone to (re)send contact photos. The watch's contacts provider
     *  has no photo data for many contacts, so the phone is the only source. */
    suspend fun requestAvatars(context: Context) = send(context, AVATARS_PATH)

    suspend fun requestFromPhone(context: Context) = send(context, REQUEST_PATH)

    /** Sends [path] to the phone app (capability-advertising node preferred). */
    private suspend fun send(context: Context, path: String) {
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
                runCatching { messageClient.sendMessage(node.id, path, ByteArray(0)).await() }
                    .onFailure { Log.w(TAG, "$path to ${node.id} failed: ${it.message}") }
            }
        } catch (e: Exception) {
            Log.w(TAG, "send($path) failed: ${e.message}")
        }
    }
}
