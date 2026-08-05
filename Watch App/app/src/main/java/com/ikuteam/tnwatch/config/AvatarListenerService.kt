package com.ikuteam.tnwatch.config

import android.util.Log
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import com.ikuteam.tnwatch.data.AvatarStore
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.runBlocking

/**
 * Receives contact photos the phone publishes at "/tnwatch/avatar/<key>" (see
 * WatchAvatarSync on the phone) and caches them for the chat list avatars.
 */
class AvatarListenerService : WearableListenerService() {

    override fun onDataChanged(dataEvents: DataEventBuffer) {
        for (event in dataEvents) {
            if (event.type != DataEvent.TYPE_CHANGED) continue
            val path = event.dataItem.uri.path ?: continue
            if (!path.startsWith(PATH_PREFIX)) continue
            val key = path.removePrefix(PATH_PREFIX)
            if (key.isBlank()) continue

            val asset = DataMapItem.fromDataItem(event.dataItem).dataMap.getAsset("photo") ?: continue
            try {
                // Assets stream separately from the DataItem; pull the bytes now.
                val bytes = runBlocking {
                    Wearable.getDataClient(this@AvatarListenerService)
                        .getFdForAsset(asset).await()
                        .inputStream.use { it.readBytes() }
                }
                if (bytes.isNotEmpty()) AvatarStore.save(this, key, bytes)
            } catch (e: Exception) {
                Log.w(TAG, "avatar $key failed: ${e.message}")
            }
        }
    }

    companion object {
        private const val TAG = "TnWatchAvatars"
        const val PATH_PREFIX = "/tnwatch/avatar/"
    }
}
