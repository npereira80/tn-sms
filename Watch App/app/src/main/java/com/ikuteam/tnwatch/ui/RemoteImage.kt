package com.ikuteam.tnwatch.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import coil.compose.AsyncImage
import com.ikuteam.tnwatch.data.ImageStore
import com.ikuteam.tnwatch.data.Repository
import java.io.File

/**
 * Message image (MMS attachment / iMessage photo).
 *
 * Coil is pointed at a locally cached file rather than the URL, because the fetch
 * has to be able to run on the phone: off Wi-Fi the watch can't reach the servers
 * itself, so [ImageStore] pulls the bytes over Bluetooth via the phone. Already
 * cached photos render with no connection at all.
 */
@Composable
fun RemoteImage(
    url: String,
    repo: Repository,
    modifier: Modifier = Modifier,
    contentScale: ContentScale = ContentScale.Crop,
) {
    val context = LocalContext.current
    var file by remember(url) { mutableStateOf<File?>(null) }

    LaunchedEffect(url) {
        val headers = repo.syncAuthHeader(url)?.let { (name, value) -> mapOf(name to value) }.orEmpty()
        file = ImageStore.get(context, url, headers)
    }

    file?.let {
        AsyncImage(
            model = it,
            contentDescription = null,
            contentScale = contentScale,
            modifier = modifier,
        )
    }
}
