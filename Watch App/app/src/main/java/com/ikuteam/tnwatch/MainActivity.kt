package com.ikuteam.tnwatch

import android.Manifest
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent
import android.view.ViewConfiguration
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
import com.ikuteam.tnwatch.config.ConfigRequester
import com.ikuteam.tnwatch.config.ConfigStore
import com.ikuteam.tnwatch.config.TnConfig
import com.ikuteam.tnwatch.ui.RotaryBus
import com.ikuteam.tnwatch.ui.WearApp
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    private val contactsPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* best-effort */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        contactsPermission.launch(Manifest.permission.READ_CONTACTS)
        applyConfigFromIntent(intent)

        // Ask the phone to (re)send both backends' credentials.
        lifecycleScope.launch { ConfigRequester.requestFromPhone(applicationContext) }

        val repo = TnWatchApp.repo(this)
        setContent { WearApp(repo) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        applyConfigFromIntent(intent)
    }

    /**
     * Forward crown / rotating-bezel input to whichever list is on screen.
     * Handled here (rather than via Compose's focus-dependent
     * onRotaryScrollEvent) so scrolling works without fighting for focus.
     */
    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_SCROLL &&
            event.isFromSource(InputDevice.SOURCE_ROTARY_ENCODER)
        ) {
            val factor = ViewConfiguration.get(this).scaledVerticalScrollFactor
            // Negated: rotating "up" (positive axis) should scroll content up.
            RotaryBus.emit(-event.getAxisValue(MotionEvent.AXIS_SCROLL) * factor)
            return true
        }
        return super.onGenericMotionEvent(event)
    }

    /**
     * Manual config override, for setup/debugging without the phone:
     *
     *   adb shell am start -n com.bluebubbles.messaging/com.ikuteam.tnwatch.MainActivity \
     *     --es syncUrl https://sms.example.net --es syncSecret SECRET \
     *     --es bbUrl https://bb.example.com --es bbPassword PASSWORD
     *
     * Only the extras present are applied; the rest keep their stored values.
     */
    private fun applyConfigFromIntent(intent: Intent?) {
        val e = intent?.extras ?: return
        val keys = listOf("syncUrl", "syncSecret", "bbUrl", "bbPassword")
        if (keys.none { e.containsKey(it) }) return
        ConfigStore.load(this)
        ConfigStore.merge(
            this,
            TnConfig(
                syncUrl = e.getString("syncUrl", ""),
                syncSecret = e.getString("syncSecret", ""),
                bbUrl = e.getString("bbUrl", ""),
                bbPassword = e.getString("bbPassword", ""),
            ),
        )
        Log.i("TnWatch", "Config applied from intent extras")
    }

    override fun onResume() {
        super.onResume()
        TnWatchApp.repo(this).refresh()
    }
}
