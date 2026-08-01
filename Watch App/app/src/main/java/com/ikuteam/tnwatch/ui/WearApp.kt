package com.ikuteam.tnwatch.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController
import com.ikuteam.tnwatch.data.Repository
import com.ikuteam.tnwatch.data.UiChat

@Composable
fun WearApp(repo: Repository) {
    MaterialTheme {
        val nav = rememberSwipeDismissableNavController()
        var selected by remember { mutableStateOf<UiChat?>(null) }

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
