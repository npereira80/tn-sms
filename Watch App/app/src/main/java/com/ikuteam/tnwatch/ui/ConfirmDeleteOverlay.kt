package com.ikuteam.tnwatch.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text

/**
 * Delete / Cancel confirmation, drawn over the current screen. Kept as an overlay
 * (not a navigation destination) for the same reason as the image viewer: routing
 * short-lived screens through the nav host left artefacts behind on dismiss.
 */
@Composable
fun ConfirmDeleteOverlay(
    title: String,
    detail: String? = null,
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
) {
    BackHandler(enabled = true) { onCancel() }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xF2000000))
            .padding(horizontal = 12.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = title,
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.button,
        )
        if (!detail.isNullOrBlank()) {
            Text(
                text = detail,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                color = Color(0xFF9A9AA0),
                style = MaterialTheme.typography.caption2,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
        Chip(
            modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
            onClick = onConfirm,
            colors = ChipDefaults.primaryChipColors(
                backgroundColor = Color(0xFFB3261E),
                contentColor = Color.White,
            ),
            label = { Text("Delete", maxLines = 1) },
        )
        Chip(
            modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
            onClick = onCancel,
            colors = ChipDefaults.secondaryChipColors(),
            label = { Text("Cancel", maxLines = 1) },
        )
    }
}
