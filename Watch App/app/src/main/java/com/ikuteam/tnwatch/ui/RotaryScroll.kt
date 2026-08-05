package com.ikuteam.tnwatch.ui

import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.wear.compose.foundation.lazy.ScalingLazyListState
import kotlinx.coroutines.flow.MutableSharedFlow

/**
 * Rotary (crown / bezel) scrolling.
 *
 * Compose's `onRotaryScrollEvent` only fires for a FOCUSED composable, and
 * reliably taking focus inside a swipe-dismissable nav host proved flaky, so the
 * Activity forwards raw rotary MotionEvents into this bus (see
 * MainActivity.onGenericMotionEvent) and whichever list is on screen consumes
 * them. Deterministic, no focus required.
 */
object RotaryBus {
    /** Scroll deltas in pixels; replay 0 so stale events aren't re-applied. */
    val events = MutableSharedFlow<Float>(replay = 0, extraBufferCapacity = 64)

    fun emit(deltaPx: Float) {
        events.tryEmit(deltaPx)
    }
}

/** Scrolls [state] in response to rotary input while this screen is composed. */
@Composable
fun RotaryScrollHandler(state: ScalingLazyListState) {
    LaunchedEffect(state) {
        RotaryBus.events.collect { delta ->
            runCatching { state.scrollBy(delta) }
        }
    }
}
