package com.ikuteam.tnwatch.data

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.ContactsContract
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Contact names + photos for message addresses, from the watch's own contacts
 * (which include Google contacts when contacts sync is on).
 *
 * Matching is done on the last 8 digits rather than via PhoneLookup: the sync
 * server stores whatever format the message arrived in (often national, e.g.
 * "912345678") while contacts are usually E.164 ("+351912345678"), and a SIM-less
 * watch has no country to normalise with — so PhoneLookup missed those and only
 * iMessage chats (already E.164) resolved. The index is built once and cached.
 */
object Contacts {
    private const val TAG = "TnWatch"

    private data class Entry(val name: String, val photo: String?)

    private var index: Map<String, Entry>? = null
    private val cache = HashMap<String, Entry?>()

    fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED

    /** Display name for [address], falling back to the address itself. */
    fun displayName(context: Context, address: String): String =
        entryFor(context, address)?.name ?: address

    /** Contact photo URI for [address], or null when there isn't one. */
    fun photoUri(context: Context, address: String): String? =
        entryFor(context, address)?.photo

    /** Call after the contacts permission is granted so the index is rebuilt. */
    fun invalidate() {
        index = null
        cache.clear()
    }

    // ---- internals --------------------------------------------------------

    /** Suffix key: enough digits to be unique, short enough to survive
     *  national vs international formatting differences. */
    private fun suffixKey(digits: String): String = digits.takeLast(8)

    private fun entryFor(context: Context, address: String): Entry? {
        if (cache.containsKey(address)) return cache[address]

        var found: Entry? = null
        val trimmed = address.trim()
        // Only phone numbers can match a contact: skip emails and alphanumeric
        // sender IDs (banks, OTP services).
        if (trimmed.isNotEmpty() && !trimmed.contains("@") && trimmed.none { it.isLetter() }) {
            val digits = trimmed.filter { it.isDigit() }
            if (digits.length >= 6) {
                val idx = index ?: buildIndex(context).also { index = it }
                found = idx[suffixKey(digits)]
            }
        }
        cache[address] = found
        return found
    }

    private fun buildIndex(context: Context): Map<String, Entry> {
        val out = HashMap<String, Entry>()
        if (!hasPermission(context)) {
            Log.w(TAG, "contacts index: no READ_CONTACTS permission")
            return out
        }
        var rows = 0
        var withPhoto = 0
        try {
            context.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER,
                    ContactsContract.CommonDataKinds.Phone.PHOTO_URI,
                    // Wear often syncs only the small thumbnail, not the full photo.
                    ContactsContract.CommonDataKinds.Phone.PHOTO_THUMBNAIL_URI,
                ),
                null, null, null,
            )?.use { c ->
                while (c.moveToNext()) {
                    rows++
                    val name = c.getString(0)?.takeIf { it.isNotBlank() } ?: continue
                    val number = c.getString(1) ?: continue
                    val photo = (if (c.isNull(2)) null else c.getString(2))
                        ?: (if (c.isNull(3)) null else c.getString(3))
                    if (photo != null) withPhoto++
                    val digits = number.filter { it.isDigit() }
                    if (digits.length < 6) continue
                    val key = suffixKey(digits)
                    val existing = out[key]
                    // Keep the entry that has a photo when a contact has several
                    // numbers sharing this suffix.
                    if (existing == null || (existing.photo == null && photo != null)) {
                        out[key] = Entry(name, photo)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "contacts index failed: ${e.javaClass.simpleName}: ${e.message}")
        }
        Log.i(TAG, "contacts index: rows=$rows keys=${out.size} withPhoto=$withPhoto")
        return out
    }
}
