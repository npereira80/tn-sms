package com.ikuteam.tnwatch.config

import android.util.Log
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import com.ikuteam.tnwatch.net.Relay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.tasks.await

/**
 * Receives the result of a request the phone performed for us (see Relay on the
 * watch and WatchHttpRelay on the phone). The body travels as an Asset, so a
 * large /delta response isn't limited by the Data Layer message size cap.
 */
class RelayReplyService : WearableListenerService() {

    override fun onDataChanged(dataEvents: DataEventBuffer) {
        for (event in dataEvents) {
            if (event.type != DataEvent.TYPE_CHANGED) continue
            val path = event.dataItem.uri.path ?: continue
            if (!path.startsWith(Relay.REPLY_PREFIX)) continue
            val id = path.removePrefix(Relay.REPLY_PREFIX)
            if (id.isBlank()) continue

            val map = DataMapItem.fromDataItem(event.dataItem).dataMap
            val code = map.getInt("code", 0)
            val asset = map.getAsset("body")
            val bytes = if (asset == null) {
                ByteArray(0)
            } else {
                try {
                    runBlocking {
                        Wearable.getDataClient(this@RelayReplyService)
                            .getFdForAsset(asset).await()
                            .inputStream.use { it.readBytes() }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "relay reply $id body failed: ${e.message}")
                    ByteArray(0)
                }
            }
            Relay.complete(id, code, bytes)
        }
    }

    companion object {
        private const val TAG = "TnWatchRelay"
    }
}
