package com.ikuteam.tnwatch.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController
import com.ikuteam.tnwatch.data.Repository
import com.ikuteam.tnwatch.data.Status
import com.ikuteam.tnwatch.data.UiChat

@Composable
fun WearApp(repo: Repository) {
    MaterialTheme {
        val nav = rememberSwipeDismissableNavController()
        var selected by remember { mutableStateOf<UiChat?>(null) }

        val net by repo.net.collectAsStateWithLifecycle()
        val syncing by repo.syncing.collectAsStateWithLifecycle()
        val status by repo.status.collectAsStateWithLifecycle()
        val chats by repo.chats.collectAsStateWithLifecycle()

        // Continue the splash until there's something real to show, so the icon
        // doesn't flash straight into an empty list. Capped so a genuinely empty
        // account (or a first run) still reaches the UI promptly.
        var booting by remember { mutableStateOf(true) }
        LaunchedEffect(Unit) {
            withTimeoutOrNull(2000) {
                snapshotFlow { chats.isNotEmpty() || status != Status.FirstSync }
                    .first { it }
            }
            booting = false
        }
        if (booting) {
            LoadingScreen()
        } else {
            Column(Modifier.fillMaxSize()) {
                // Thin status strip: problems take priority over sync progress.
                val banner = net.banner
                when {
                    banner != null -> StatusBanner(banner)
                    syncing && status != Status.FirstSync -> SyncingBanner()
                }

                SwipeDismissableNavHost(navController = nav, startDestination = "list") {
                    composable("list") {
                        ChatListScreen(repo) { chat ->
                            selected = chat
                            nav.navigate("thread")
                        }
                    }
                    composable("thread") {
                        val chat = selected
                        if (chat == null) nav.popBackStack() else ThreadScreen(repo, chat)
                    }
                }
            }
        }
    }
}
