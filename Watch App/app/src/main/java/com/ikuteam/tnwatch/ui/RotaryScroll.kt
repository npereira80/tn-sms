package com.ikuteam.tnwatch.ui

import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.rotary.onRotaryScrollEvent
import androidx.wear.compose.foundation.lazy.ScalingLazyListState
import kotlinx.coroutines.launch

/**
 * Makes a [ScalingLazyColumn] respond to the rotating side button / bezel.
 * Rotary events only reach a focused composable, so this also takes focus.
 */
@OptIn(ExperimentalComposeUiApi::class)
fun Modifier.rotaryScroll(state: ScalingLazyListState): Modifier = composed {
    val focusRequester = remember { FocusRequester() }
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        // Safe to ignore: focus can be unavailable while the screen is leaving.
        runCatching { focusRequester.requestFocus() }
    }

    this
        .onRotaryScrollEvent { event ->
            scope.launch { state.scrollBy(event.verticalScrollPixels) }
            true
        }
        .focusRequester(focusRequester)
        .focusable()
}
