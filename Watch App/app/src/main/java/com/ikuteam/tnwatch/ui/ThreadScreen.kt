package com.ikuteam.tnwatch.ui

import android.app.RemoteInput
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.ListHeader
import androidx.wear.compose.material.Text
import androidx.wear.compose.material.ToggleChip
import androidx.wear.input.RemoteInputIntentHelper
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.ikuteam.tnwatch.data.Repository
import com.ikuteam.tnwatch.data.Service
import com.ikuteam.tnwatch.data.UiChat
import com.ikuteam.tnwatch.data.UiMessage
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

private const val KEY_REPLY = "tnwatch_reply"
private val IMESSAGE_BLUE = Color(0xFF0A84FF)
private val SMS_GREEN = Color(0xFF34C759)
private val RECEIVED = Color(0xFF3A3A3C)

/** header + messages + optional mode chip + reply chip */
private fun itemCountFor(messageCount: Int, supportsBoth: Boolean): Int =
    1 + messageCount + (if (supportsBoth) 1 else 0) + 1

@Composable
fun ThreadScreen(repo: Repository, chat: UiChat) {
    var messages by remember { mutableStateOf<List<UiMessage>>(emptyList()) }
    var mode by remember { mutableStateOf(chat.defaultService) }
    val scope = rememberCoroutineScope()
    val listState = rememberScalingLazyListState()

    LaunchedEffect(chat.key) {
        while (isActive) {
            messages = repo.thread(chat)
            delay(4000)
        }
    }

    // Open on the LATEST message (and follow new arrivals) instead of the oldest.
    LaunchedEffect(chat.key, messages.size) {
        if (messages.isNotEmpty()) {
            listState.scrollToItem(itemCountFor(messages.size, chat.supportsBoth) - 1)
        }
    }

    val replyLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val data = result.data ?: return@rememberLauncherForActivityResult
        val text = RemoteInput.getResultsFromIntent(data)?.getCharSequence(KEY_REPLY)?.toString()
        if (!text.isNullOrBlank()) {
            scope.launch {
                repo.send(chat, mode, text)
                messages = repo.thread(chat)
            }
        }
    }

    val startReply = {
        val intent = RemoteInputIntentHelper.createActionRemoteInputIntent()
        val remoteInputs = listOf(
            RemoteInput.Builder(KEY_REPLY).setLabel("Reply").setAllowFreeFormInput(true).build(),
        )
        RemoteInputIntentHelper.putRemoteInputsExtra(intent, remoteInputs)
        replyLauncher.launch(intent)
    }

    ScalingLazyColumn(
        modifier = Modifier.fillMaxSize().rotaryScroll(listState),
        state = listState,
    ) {
        item { ListHeader { Text(chat.title, maxLines = 1) } }

        items(messages, key = { it.id }) { m -> MessageBubble(m, repo) }

        if (chat.supportsBoth) {
            item {
                ToggleChip(
                    modifier = Modifier.fillMaxWidth(),
                    checked = mode == Service.IMESSAGE,
                    onCheckedChange = { mode = if (it) Service.IMESSAGE else Service.SMS },
                    label = { Text("Send as ${if (mode == Service.IMESSAGE) "iMessage" else "SMS"}") },
                    toggleControl = {
                        Text(if (mode == Service.IMESSAGE) "iMsg" else "SMS")
                    },
                )
            }
        }

        item {
            // Reply button carries the service colour: green for SMS, blue for iMessage.
            val tint = if (mode == Service.IMESSAGE) IMESSAGE_BLUE else SMS_GREEN
            Chip(
                modifier = Modifier.fillMaxWidth(),
                onClick = startReply,
                colors = ChipDefaults.primaryChipColors(
                    backgroundColor = tint,
                    contentColor = Color.White,
                ),
                label = { Text("Reply · ${if (mode == Service.IMESSAGE) "iMessage" else "SMS"}") },
            )
        }
    }
}

@Composable
private fun MessageBubble(m: UiMessage, repo: Repository) {
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
            .padding(end = if (m.fromMe) 0.dp else 10.dp, start = if (m.fromMe) 10.dp else 0.dp),
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
                modifier = Modifier.size(120.dp).clip(RoundedCornerShape(12.dp)),
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
    }
}
