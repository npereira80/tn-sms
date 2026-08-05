package com.ikuteam.tnwatch.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.CircularProgressIndicator
import androidx.wear.compose.material.ListHeader
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text
import com.ikuteam.tnwatch.data.Repository
import com.ikuteam.tnwatch.data.Service
import com.ikuteam.tnwatch.data.Status
import com.ikuteam.tnwatch.data.UiChat

@Composable
fun ChatListScreen(repo: Repository, onOpen: (UiChat) -> Unit) {
    val chats by repo.chats.collectAsStateWithLifecycle()
    val status by repo.status.collectAsStateWithLifecycle()
    val listState = rememberScalingLazyListState()
    // Long-pressed chat awaiting delete confirmation.
    var pendingDelete by remember { mutableStateOf<UiChat?>(null) }

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

    Box(Modifier.fillMaxSize()) {
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
            ChatRow(
                chat = chat,
                onClick = { onOpen(chat) },
                // iMessage-only threads can't be deleted (no BlueBubbles API).
                onLongClick = if (Service.SMS in chat.services) {
                    { pendingDelete = chat }
                } else {
                    null
                },
            )
        }
    }

        pendingDelete?.let { chat ->
            ConfirmDeleteOverlay(
                title = "Delete conversation?",
                detail = chat.title,
                onConfirm = {
                    repo.deleteChat(chat)
                    pendingDelete = null
                },
                onCancel = { pendingDelete = null },
            )
        }
    }
}

/**
 * Contact-photo row: avatar, bold name, muted snippet. No chip background, so the
 * list reads like the phone's conversation list rather than a stack of buttons.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChatRow(chat: UiChat, onClick: () -> Unit, onLongClick: (() -> Unit)?) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(address = chat.smsAddress ?: chat.key.takeIf { !chat.isGroup }, title = chat.title)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                text = chat.title,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                fontWeight = if (chat.unread) FontWeight.Bold else FontWeight.SemiBold,
                style = MaterialTheme.typography.button,
            )
            Text(
                text = chat.snippet,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                color = Color(0xFF9A9AA0),
                style = MaterialTheme.typography.caption2,
            )
        }
        // Unread indicator: one dot, coloured by the service the newest message
        // arrived on (blue = iMessage, green = SMS). Nothing when read.
        if (chat.unread) {
            Box(
                Modifier
                    .padding(start = 4.dp)
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(
                        if (chat.lastService == Service.IMESSAGE) Color(0xFF0A84FF)
                        else Color(0xFF34C759),
                    ),
            )
        }
    }
}
