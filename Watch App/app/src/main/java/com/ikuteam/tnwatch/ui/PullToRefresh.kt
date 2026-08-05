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
                // Finger drags only, and only clearly-vertical ones: the
                // swipe-to-dismiss (back) gesture is horizontal and must not
                // trigger a sync.
                if (source != NestedScrollSource.Drag) return Offset.Zero
                if (kotlin.math.abs(available.y) <= kotlin.math.abs(available.x)) return Offset.Zero

                // "At top" must be canScrollBackward, NOT centerItemIndex == 0:
                // in a ScalingLazyColumn the *centred* item at scroll-top is a
                // couple of items in, so the old check never became true and
                // pull-to-refresh never fired at all.
                val atTop = !state.canScrollBackward
                if (atTop && available.y > 0f) {
                    overscroll += available.y
                    if (!fired && overscroll > 90f) {
                        fired = true
                        onRefresh()
                    }
                } else if (!atTop) {
                    overscroll = 0f
                    fired = false
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
