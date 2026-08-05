package com.ikuteam.tnwatch.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
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

    ScalingLazyColumn(
        modifier = Modifier.fillMaxSize().rotaryScroll(listState),
        state = listState,
    ) {
        item { ListHeader { Text("Messages") } }

        if (chats.isEmpty()) {
            item {
                Text(
                    when (status) {
                        Status.NeedsConfig -> "Waiting for setup from your phone…"
                        Status.Loading -> "Loading…"
                        Status.Error -> "Can't reach your servers. Check Wi-Fi."
                        Status.Ready -> "No conversations yet."
                    },
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
