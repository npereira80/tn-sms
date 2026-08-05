package com.ikuteam.tnwatch.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material.Text
import coil.compose.AsyncImage
import com.ikuteam.tnwatch.data.AvatarStore
import com.ikuteam.tnwatch.data.Contacts

/**
 * Circular contact thumbnail: the device contact photo when we have one,
 * otherwise the contact's initials on a colour derived from their name.
 */
@Composable
fun Avatar(address: String?, title: String, size: Dp = 40.dp) {
    val ctx = LocalContext.current
    // Photos pushed from the phone win: the watch's contacts provider has no
    // photo data for many contacts, so this is the only source for those.
    val pushedRevision by AvatarStore.revision.collectAsStateWithLifecycle()
    val photo = remember(address, pushedRevision) {
        address?.let { addr ->
            AvatarStore.fileFor(ctx, addr)?.absolutePath ?: Contacts.photoUri(ctx, addr)
        }
    }

    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .background(if (photo == null) colorFor(title) else Color(0xFF3A3A3C)),
        contentAlignment = Alignment.Center,
    ) {
        if (photo != null) {
            AsyncImage(
                model = photo,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Text(
                text = initials(title),
                color = Color.White,
                fontWeight = FontWeight.Medium,
                fontSize = (size.value * 0.36f).sp,
            )
        }
    }
}

private fun initials(title: String): String {
    val words = title.trim().split(Regex("\\s+")).filter { it.isNotBlank() }
    return when {
        words.isEmpty() -> "?"
        // A phone number / short code: use a generic glyph rather than digits.
        words[0].none { it.isLetter() } -> "#"
        words.size == 1 -> words[0].take(1).uppercase()
        else -> (words[0].take(1) + words[1].take(1)).uppercase()
    }
}

/** Stable per-contact colour so avatars stay recognisable between launches. */
private fun colorFor(seed: String): Color {
    val palette = listOf(
        Color(0xFF2563EB), Color(0xFF7C3AED), Color(0xFFDB2777),
        Color(0xFFEA580C), Color(0xFF16A34A), Color(0xFF0891B2),
        Color(0xFF9333EA), Color(0xFFCA8A04),
    )
    val h = seed.fold(0) { acc, c -> acc * 31 + c.code }
    return palette[(h.hashCode().ushr(1)) % palette.size]
}
