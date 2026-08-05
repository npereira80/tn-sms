package com.ikuteam.tnwatch.ui

import android.app.RemoteInput
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.ListHeader
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text
import androidx.wear.input.RemoteInputIntentHelper
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.ikuteam.tnwatch.data.Repository
import com.ikuteam.tnwatch.data.Service
import com.ikuteam.tnwatch.data.UiChat
import com.ikuteam.tnwatch.data.UiMessage

private const val KEY_REPLY = "tnwatch_reply"
private val IMESSAGE_BLUE = Color(0xFF0A84FF)
private val SMS_GREEN = Color(0xFF34C759)
private val RECEIVED = Color(0xFF3A3A3C)

@Composable
fun ThreadScreen(
    repo: Repository,
    chat: UiChat,
    onOpenImage: (String) -> Unit,
) {
    var messages by remember { mutableStateOf<List<UiMessage>>(emptyList()) }
    // Which service the pending reply will use; set when a Reply button is tapped.
    var replyService by remember { mutableStateOf(chat.defaultService) }
    val listState = rememberScalingLazyListState()
    val revision by repo.revision.collectAsStateWithLifecycle()

    // Reload from the local cache whenever stored messages change.
    LaunchedEffect(chat.key, revision) {
        messages = repo.thread(chat)
    }

    // Open on the LATEST message and follow new arrivals.
    LaunchedEffect(chat.key, messages.size) {
        if (messages.isNotEmpty()) {
            listState.scrollToItem(itemCount(messages.size, chat) - 1)
        }
    }

    val replyLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val data = result.data ?: return@rememberLauncherForActivityResult
        val text = RemoteInput.getResultsFromIntent(data)?.getCharSequence(KEY_REPLY)?.toString()
        if (!text.isNullOrBlank()) {
            repo.send(chat, replyService, text)   // queued; sends when reachable
        }
    }

    fun startReply(service: Service) {
        replyService = service
        val intent = RemoteInputIntentHelper.createActionRemoteInputIntent()
        val remoteInputs = listOf(
            RemoteInput.Builder(KEY_REPLY).setLabel("Reply").setAllowFreeFormInput(true).build(),
        )
        RemoteInputIntentHelper.putRemoteInputsExtra(intent, remoteInputs)
        replyLauncher.launch(intent)
    }

    RotaryScrollHandler(listState)

    ScalingLazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .pullToRefresh(listState) { repo.refresh() },
        state = listState,
    ) {
        item { ListHeader { Text(chat.title, maxLines = 1) } }

        items(messages, key = { it.id }) { m -> MessageBubble(m, repo, onOpenImage) }

        // One button per available service, coloured to match its bubbles.
        if (chat.canIMessage) {
            item {
                ReplyButton("Reply · iMessage", IMESSAGE_BLUE) { startReply(Service.IMESSAGE) }
            }
        }
        if (chat.canSms) {
            item {
                ReplyButton("Reply · SMS", SMS_GREEN) { startReply(Service.SMS) }
            }
        }
    }
}

/** header + messages + one button per available service */
private fun itemCount(messageCount: Int, chat: UiChat): Int {
    var n = 1 + messageCount
    if (chat.canIMessage) n++
    if (chat.canSms) n++
    return n
}

@Composable
private fun ReplyButton(label: String, tint: Color, onClick: () -> Unit) {
    Chip(
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
        onClick = onClick,
        colors = ChipDefaults.primaryChipColors(backgroundColor = tint, contentColor = Color.White),
        label = { Text(label, maxLines = 1) },
    )
}

@Composable
private fun MessageBubble(m: UiMessage, repo: Repository, onOpenImage: (String) -> Unit) {
    val bg = when {
        !m.fromMe -> RECEIVED
        m.service == Service.IMESSAGE -> IMESSAGE_BLUE
        else -> SMS_GREEN
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
            // Inset the opposite edge so sent/received are easy to tell apart.
            .padding(end = if (m.fromMe) 0.dp else 15.dp, start = if (m.fromMe) 15.dp else 0.dp),
        horizontalAlignment = if (m.fromMe) Alignment.End else Alignment.Start,
    ) {
        m.imageUrl?.let { url ->
            val ctx = LocalContext.current
            val request = ImageRequest.Builder(ctx)
                .data(url)
                .apply { repo.syncAuthHeader(url)?.let { (k, v) -> addHeader(k, v) } }
                .build()
            AsyncImage(
                model = request,
                contentDescription = null,
                // Crop, not fit: with a fixed square frame, "fit" letterboxes the
                // photo and the rounded clip would round transparent bars.
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(120.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .clickable { onOpenImage(url) },
            )
        }
        if (m.text.isNotBlank()) {
            Text(
                text = m.text,
                color = Color.White,
                modifier = Modifier
                    .background(bg, RoundedCornerShape(14.dp))
                    .padding(horizontal = 10.dp, vertical = 6.dp),
            )
        }
        if (m.pending) {
            Text(
                text = "Sending…",
                style = MaterialTheme.typography.caption3,
                color = Color(0xFF9A9AA0),
            )
        }
    }
}
