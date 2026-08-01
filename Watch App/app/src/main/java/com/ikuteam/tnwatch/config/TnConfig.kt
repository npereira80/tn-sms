package com.ikuteam.tnwatch.config

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Credentials for both backends, provisioned from the phone over the Wear Data
 * Layer (see [ConfigListenerService]). The watch never asks the user to type
 * these; the phone app is the single source of truth.
 *
 * - sync* : the SMS sync server (SMS/MMS over the Wi-Fi relay).
 * - bb*   : the BlueBubbles server (iMessage).
 */
@Serializable
data class TnConfig(
    val syncUrl: String = "",
    val syncSecret: String = "",
    val syncToken: String? = null, // if the phone pre-registered a watch device
    val bbUrl: String = "",
    val bbPassword: String = "",
) {
    val hasSync: Boolean get() = syncUrl.isNotBlank() && (syncSecret.isNotBlank() || !syncToken.isNullOrBlank())
    val hasBB: Boolean get() = bbUrl.isNotBlank() && bbPassword.isNotBlank()
    val isConfigured: Boolean get() = hasSync || hasBB
}

/** Persists [TnConfig] and exposes it as an observable [StateFlow]. */
object ConfigStore {
    private const val PREFS = "tnwatch_config"
    private const val KEY = "config_json"
    private val json = Json { ignoreUnknownKeys = true }

    private val _state = MutableStateFlow(TnConfig())
    val state: StateFlow<TnConfig> = _state

    fun load(context: Context) {
        val raw = prefs(context).getString(KEY, null) ?: return
        runCatching { json.decodeFromString<TnConfig>(raw) }.getOrNull()?.let { _state.value = it }
    }

    fun save(context: Context, config: TnConfig) {
        prefs(context).edit().putString(KEY, json.encodeToString(TnConfig.serializer(), config)).apply()
        _state.value = config
    }

    /** Merge only the non-blank fields from a provisioning push, keeping a
     *  locally-registered [TnConfig.syncToken] if the push didn't include one. */
    fun merge(context: Context, incoming: TnConfig) {
        val cur = _state.value
        save(
            context,
            cur.copy(
                syncUrl = incoming.syncUrl.ifBlank { cur.syncUrl },
                syncSecret = incoming.syncSecret.ifBlank { cur.syncSecret },
                syncToken = incoming.syncToken?.ifBlank { cur.syncToken } ?: cur.syncToken,
                bbUrl = incoming.bbUrl.ifBlank { cur.bbUrl },
                bbPassword = incoming.bbPassword.ifBlank { cur.bbPassword },
            ),
        )
    }

    fun setSyncToken(context: Context, token: String) {
        save(context, _state.value.copy(syncToken = token))
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
