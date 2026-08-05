package com.ikuteam.tnwatch.data

/** Which backend a message came from / a reply goes out on. */
enum class Service { SMS, IMESSAGE }

/** A single message shown in a thread. */
data class UiMessage(
    val id: String,
    val text: String,
    val fromMe: Boolean,
    val timestamp: Long,
    val service: Service,
    val imageUrl: String? = null, // authenticated URL for a thumbnail, if any
    val pending: Boolean = false, // queued in the outbox, not sent yet
)

/** Connectivity + per-backend reachability, shown as a banner. */
data class NetStatus(
    val online: Boolean = true,
    val smsConfigured: Boolean = false,
    val smsOk: Boolean = true,
    val bbConfigured: Boolean = false,
    val bbOk: Boolean = true,
) {
    /** Banner text, or null when everything is healthy. */
    val banner: String?
        get() = when {
            !online -> "Offline"
            smsConfigured && !smsOk && bbConfigured && !bbOk -> "Servers Offline"
            smsConfigured && !smsOk -> "SMS Offline"
            bbConfigured && !bbOk -> "iMessage Offline"
            else -> null
        }
}

/**
 * A merged conversation. A contact reachable on both backends has both
 * [smsAddress] and [bbChatGuid] set and [services] == {SMS, IMESSAGE}, so the
 * thread shows the SMS/iMessage chip.
 */
data class UiChat(
    val key: String,              // merge key (normalized address) or bb group guid
    val title: String,
    val snippet: String,
    val timestamp: Long,
    val unread: Boolean,
    val services: Set<Service>,
    val smsAddress: String? = null, // raw address to relay SMS to
    val bbChatGuid: String? = null, // BlueBubbles chat guid to send iMessage to
    val isGroup: Boolean = false,
    val lastService: Service? = null, // service the newest message arrived on
) {
    val canSms: Boolean
        get() = Service.SMS in services && smsAddress != null && Addr.isReplyable(smsAddress)
    val canIMessage: Boolean get() = Service.IMESSAGE in services && bbChatGuid != null
    val supportsBoth: Boolean get() = canSms && canIMessage
    /** No way to answer: e.g. an OTP / alphanumeric short-code sender. */
    val readOnly: Boolean get() = !canSms && !canIMessage
    /** Default reply service: iMessage when available, else SMS. */
    val defaultService: Service get() = if (canIMessage) Service.IMESSAGE else Service.SMS
}

/** Normalizes an address to the same key the sync server + BB side use, so a
 *  contact's SMS and iMessage threads merge. Phone numbers → leading "+" (if
 *  present) plus digits; emails / alphanumeric senders kept verbatim. */
object Addr {
    fun normalize(addr: String): String {
        val t = addr.trim()
        if (t.contains("@") || t.any { it.isLetter() }) return t
        val plus = if (t.startsWith("+")) "+" else ""
        return plus + t.filter { it.isDigit() }
    }

    /**
     * Can we send an SMS back to this address? Alphanumeric sender IDs (banks,
     * OTP services like "UPSPkgInfo") are one-way, exactly as the phone app shows
     * "You can't reply to this sender". Very short numeric short-codes are also
     * usually one-way, but we allow those rather than block a real contact.
     */
    fun isReplyable(addr: String?): Boolean {
        val t = addr?.trim().orEmpty()
        if (t.isEmpty()) return false
        if (t.any { it.isLetter() }) return false     // alphanumeric sender ID
        return t.any { it.isDigit() }
    }
}
