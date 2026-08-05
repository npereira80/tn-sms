package com.ikuteam.tnwatch.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text

/** Thin banner across the top for connectivity / backend problems. */
@Composable
fun StatusBanner(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        color = Color.White,
        textAlign = TextAlign.Center,
        style = MaterialTheme.typography.caption2,
        modifier = modifier
            .fillMaxWidth()
            .background(Color(0xFF8E1F1F))
            .padding(vertical = 2.dp),
    )
}

/** Same strip, used to show that a sync is in flight. */
@Composable
fun SyncingBanner(modifier: Modifier = Modifier) {
    Text(
        text = "Syncing…",
        color = Color.White,
        textAlign = TextAlign.Center,
        style = MaterialTheme.typography.caption2,
        modifier = modifier
            .fillMaxWidth()
            .background(Color(0xFF1F3A8E))
            .padding(vertical = 2.dp),
    )
}
