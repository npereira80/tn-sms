package com.ikuteam.tnwatch.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.Velocity
import androidx.wear.compose.foundation.lazy.ScalingLazyListState

/**
 * Pull-to-refresh for a [ScalingLazyColumn]: once the list is at the top and the
 * user keeps dragging down past a threshold, [onRefresh] fires (once per gesture).
 * Wear has no built-in pull-to-refresh, so this rides the nested-scroll overscroll.
 */
@Composable
fun Modifier.pullToRefresh(
    state: ScalingLazyListState,
    onRefresh: () -> Unit,
): Modifier {
    val connection = remember(state, onRefresh) {
        object : NestedScrollConnection {
            private var overscroll = 0f
            private var fired = false

            override fun onPostScroll(
                consumed: Offset,
                available: Offset,
                source: NestedScrollSource,
            ): Offset {
                val atTop = state.centerItemIndex <= 0 && state.centerItemScrollOffset <= 0
                if (atTop && available.y > 0f) {
                    overscroll += available.y
                    if (!fired && overscroll > 120f) {
                        fired = true
                        onRefresh()
                    }
                } else if (available.y < 0f) {
                    overscroll = 0f
                }
                return Offset.Zero
            }

            override suspend fun onPreFling(available: Velocity): Velocity {
                overscroll = 0f
                fired = false
                return Velocity.Zero
            }
        }
    }
    return this.nestedScroll(connection)
}
