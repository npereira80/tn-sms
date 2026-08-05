package com.ikuteam.tnwatch.data

import android.content.Context
import com.ikuteam.tnwatch.net.Http
import java.io.File
import java.security.MessageDigest

/**
 * Disk cache for message images (MMS attachments and iMessage photos).
 *
 * Fetching goes through [Http.execBytes], so a thumbnail loads over the watch's
 * own network when it has one and otherwise via the phone over Bluetooth. Cached
 * on disk, so a photo you've already seen also renders with no connection at all.
 */
object ImageStore {

    private fun dir(context: Context): File =
        File(context.filesDir, "images").apply { if (!exists()) mkdirs() }

    private fun keyFor(url: String): String {
        val digest = MessageDigest.getInstance("SHA-1").digest(url.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }

    private fun fileFor(context: Context, url: String) = File(dir(context), keyFor(url))

    /** Cached copy of [url], downloading it if needed. Null if it can't be fetched. */
    suspend fun get(context: Context, url: String, headers: Map<String, String>): File? {
        val file = fileFor(context, url)
        if (file.exists() && file.length() > 0) return file

        val bytes = Http.execBytes(url, headers) ?: return null
        if (bytes.isEmpty()) return null
        return try {
            file.writeBytes(bytes)
            file
        } catch (e: Exception) {
            null
        }
    }

    fun sizeBytes(context: Context): Long =
        dir(context).listFiles()?.sumOf { it.length() } ?: 0L

    fun clear(context: Context) {
        dir(context).listFiles()?.forEach { it.delete() }
    }
}
