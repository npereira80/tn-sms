package com.ikuteam.tnwatch.net

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Booleans on the wire arrive in whatever shape the backend's storage produced:
 * SQLite (the sync server) emits 1/0, BlueBubbles emits true/false, and either
 * can send them as strings. A strict Boolean field made one such value fail the
 * WHOLE payload, so parse all of these forms.
 */
object LooseBoolean : KSerializer<Boolean> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("LooseBoolean", PrimitiveKind.BOOLEAN)

    override fun deserialize(decoder: Decoder): Boolean {
        val input = decoder as? JsonDecoder ?: return decoder.decodeBoolean()
        val prim = input.decodeJsonElement() as? JsonPrimitive ?: return false
        prim.booleanOrNull?.let { return it }
        prim.intOrNull?.let { return it != 0 }
        return when (prim.content.lowercase()) {
            "true", "1", "yes" -> true
            else -> false
        }
    }

    override fun serialize(encoder: Encoder, value: Boolean) = encoder.encodeBoolean(value)
}

// ---- SMS sync server ------------------------------------------------------

@Serializable
data class RegisterResponse(val token: String? = null, val id: String? = null)

@Serializable
data class SyncAttachment(
    val id: String? = null,
    val mime: String = "application/octet-stream",
    val size: Long? = null,
    val sha256: String = "",
    val name: String? = null,
)

@Serializable
data class SyncMessage(
    val id: String = "",
    @SerialName("conversation_id") val conversationId: String = "",
    /** Cross-device identity. Stored so a deletion tombstone can be matched even
     *  when our cached row's server id differs (duplicate ingest, re-sync). */
    @SerialName("content_hash") val contentHash: String? = null,
    val direction: String = "in", // "in" | "out"
    val address: String = "",
    val body: String = "",
    val ts: Long = 0,
    val type: String = "sms", // "sms" | "mms"
    val status: String? = null,
    @SerialName("updated_at") val updatedAt: Long = 0,
    val attachments: List<SyncAttachment> = emptyList(),
) {
    val fromMe: Boolean get() = direction == "out"
}

@Serializable
data class SyncConversation(
    val id: String = "",
    @Serializable(with = LooseBoolean::class) val unread: Boolean = false,
)

@Serializable
data class SyncDeletion(
    @SerialName("content_hash") val contentHash: String? = null,
    @SerialName("conversation_id") val conversationId: String? = null,
    @SerialName("message_id") val messageId: String? = null,
    val ts: Long = 0,
)

/** What a conversation currently holds server-side, for pruning local copies. */
@Serializable
data class ConversationKeys(
    val ids: List<String> = emptyList(),
    val hashes: List<String> = emptyList(),
)

@Serializable
data class DeltaResponse(
    val messages: List<SyncMessage> = emptyList(),
    val conversations: List<SyncConversation> = emptyList(),
    val deletions: List<SyncDeletion> = emptyList(),
    val cursor: Long = 0,
)

// ---- BlueBubbles ----------------------------------------------------------

@Serializable
data class BBHandle(val address: String? = null)

@Serializable
data class BBAttachment(
    val guid: String = "",
    val mimeType: String? = null,
    val transferName: String? = null,
)

@Serializable
data class BBMessage(
    val guid: String = "",
    val text: String? = null,
    val dateCreated: Long? = null,
    @Serializable(with = LooseBoolean::class) val isFromMe: Boolean = false,
    val handle: BBHandle? = null,
    val attachments: List<BBAttachment> = emptyList(),
)

@Serializable
data class BBChat(
    val guid: String = "",
    val chatIdentifier: String? = null,
    val displayName: String? = null,
    val style: Int? = null, // 43 = group, 45 = 1:1
    val participants: List<BBHandle> = emptyList(),
    val lastMessage: BBMessage? = null,
)

@Serializable
data class BBChatQueryResponse(val data: List<BBChat> = emptyList())

@Serializable
data class BBMessageQueryResponse(val data: List<BBMessage> = emptyList())
