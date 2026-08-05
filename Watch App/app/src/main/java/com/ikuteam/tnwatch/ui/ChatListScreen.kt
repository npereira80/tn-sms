package com.ikuteam.tnwatch.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.CircularProgressIndicator
import androidx.wear.compose.material.ListHeader
import androidx.wear.compose.material.Text
import com.ikuteam.tnwatch.data.Repository
import com.ikuteam.tnwatch.data.Status
import com.ikuteam.tnwatch.data.UiChat

@Composable
fun ChatListScreen(repo: Repository, onOpen: (UiChat) -> Unit) {
    val chats by repo.chats.collectAsStateWithLifecycle()
    val status by repo.status.collectAsStateWithLifecycle()
    val listState = rememberScalingLazyListState()

    // First run has nothing cached yet: hold the screen on a spinner until the
    // initial sync finishes, rather than showing an empty list.
    if (status == Status.FirstSync && chats.isEmpty()) {
        Column(
            modifier = Modifier.fillMaxSize().padding(16.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            CircularProgressIndicator()
            Text(
                "Syncing…",
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
        return
    }

    RotaryScrollHandler(listState)

    ScalingLazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .pullToRefresh(listState) { repo.refresh() },
        state = listState,
    ) {
        item { ListHeader { Text("Messages") } }

        if (chats.isEmpty()) {
            item {
                Text(
                    when (status) {
                        Status.NeedsConfig -> "Waiting for setup from your phone…"
                        Status.FirstSync -> "Syncing…"
                        Status.Ready -> "No conversations yet."
                    },
                    textAlign = TextAlign.Center,
                )
            }
        }

        items(chats, key = { it.key }) { chat ->
            ChatRow(chat) { onOpen(chat) }
        }
    }
}

@Composable
private fun ChatRow(chat: UiChat, onClick: () -> Unit) {
    Chip(
        modifier = Modifier.fillMaxWidth(),
        onClick = onClick,
        colors = ChipDefaults.secondaryChipColors(),
        label = {
            Text(chat.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
        },
        secondaryLabel = {
            val prefix = if (chat.supportsBoth) "•• " else "" // •• = reachable on both
            Text(prefix + chat.snippet, maxLines = 1, overflow = TextOverflow.Ellipsis)
        },
    )
}
