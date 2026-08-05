package com.ikuteam.tnwatch.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File

/**
 * Contact photos pushed from the phone.
 *
 * The watch's own contacts provider only has photos for *some* contacts (many
 * rows come back with photo_uri and photo_thumb_uri NULL), so the phone sends
 * the missing ones over the Data Layer and they're cached here as JPEGs named by
 * the same last-8-digits key used to match addresses.
 */
object AvatarStore {
    /** Bumped when a new photo lands, so the UI recomposes. */
    private val _revision = MutableStateFlow(0)
    val revision: StateFlow<Int> = _revision

    private fun dir(context: Context): File =
        File(context.filesDir, "avatars").apply { if (!exists()) mkdirs() }

    private fun keyFor(address: String): String? {
        val digits = address.filter { it.isDigit() }
        return if (digits.length >= 6) digits.takeLast(8) else null
    }

    fun save(context: Context, key: String, bytes: ByteArray) {
        runCatching {
            File(dir(context), "$key.jpg").writeBytes(bytes)
            _revision.value = _revision.value + 1
        }
    }

    /** Local file holding this address's photo, or null when we don't have one. */
    fun fileFor(context: Context, address: String): File? {
        val key = keyFor(address) ?: return null
        val file = File(dir(context), "$key.jpg")
        return if (file.exists() && file.length() > 0) file else null
    }

    fun count(context: Context): Int = dir(context).listFiles()?.size ?: 0

    fun clear(context: Context) {
        dir(context).listFiles()?.forEach { it.delete() }
        _revision.value = _revision.value + 1
    }
}
