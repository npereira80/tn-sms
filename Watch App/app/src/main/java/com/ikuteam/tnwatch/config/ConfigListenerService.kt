package com.ikuteam.tnwatch.config

import android.util.Log
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.WearableListenerService

/**
 * Receives the config DataItem the phone app puts at "/tnwatch/config" and
 * stores it. The phone pushes this on demand (in response to a request from
 * [ConfigRequester]) and whenever its own credentials change.
 */
class ConfigListenerService : WearableListenerService() {

    override fun onDataChanged(dataEvents: DataEventBuffer) {
        for (event in dataEvents) {
            if (event.type != DataEvent.TYPE_CHANGED) continue
            val item = event.dataItem
            if (item.uri.path?.startsWith(PATH) != true) continue
            val map = DataMapItem.fromDataItem(item).dataMap
            val incoming = TnConfig(
                syncUrl = map.getString(KEY_SYNC_URL, ""),
                syncSecret = map.getString(KEY_SYNC_SECRET, ""),
                syncToken = map.getString(KEY_SYNC_TOKEN, "").ifBlank { null },
                bbUrl = map.getString(KEY_BB_URL, ""),
                bbPassword = map.getString(KEY_BB_PASSWORD, ""),
            )
            ConfigStore.load(this)
            ConfigStore.merge(this, incoming)
            Log.i(TAG, "Config provisioned from phone (sync=${incoming.syncUrl.isNotBlank()}, bb=${incoming.bbUrl.isNotBlank()})")
        }
    }

    companion object {
        private const val TAG = "TnWatchConfig"
        const val PATH = "/tnwatch/config"
        const val KEY_SYNC_URL = "syncUrl"
        const val KEY_SYNC_SECRET = "syncSecret"
        const val KEY_SYNC_TOKEN = "syncToken"
        const val KEY_BB_URL = "bbUrl"
        const val KEY_BB_PASSWORD = "bbPassword"
    }
}
