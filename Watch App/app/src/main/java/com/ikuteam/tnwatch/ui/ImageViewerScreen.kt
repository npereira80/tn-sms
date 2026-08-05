package com.ikuteam.tnwatch.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.ikuteam.tnwatch.data.Repository

/**
 * Full-screen image with pinch-to-zoom and pan, drawn as an overlay on top of the
 * thread (NOT a navigation destination — routing it through the nav host left a
 * black screen behind on dismiss). The system back gesture closes it.
 */
@Composable
fun ImageViewerOverlay(repo: Repository, url: String, onClose: () -> Unit) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }

    BackHandler(enabled = true) { onClose() }

    val transformState = rememberTransformableState { zoomChange, panChange, _ ->
        scale = (scale * zoomChange).coerceIn(1f, 5f)
        // Only allow panning while zoomed in; reset when back to fit.
        offset = if (scale > 1f) offset + panChange else Offset.Zero
    }

    val ctx = LocalContext.current
    val request = ImageRequest.Builder(ctx)
        .data(url)
        .apply { repo.syncAuthHeader(url)?.let { (k, v) -> addHeader(k, v) } }
        .build()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .transformable(transformState),
        contentAlignment = Alignment.Center,
    ) {
        AsyncImage(
            model = request,
            contentDescription = null,
            contentScale = ContentScale.Fit,
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer(
                    scaleX = scale,
                    scaleY = scale,
                    translationX = offset.x,
                    translationY = offset.y,
                ),
        )
    }
}
