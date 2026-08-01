package com.ikuteam.tnwatch

import android.Manifest
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
import com.ikuteam.tnwatch.config.ConfigRequester
import com.ikuteam.tnwatch.ui.WearApp
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    private val contactsPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* best-effort */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        contactsPermission.launch(Manifest.permission.READ_CONTACTS)

        // Ask the phone to (re)send both backends' credentials.
        lifecycleScope.launch { ConfigRequester.requestFromPhone(applicationContext) }

        val repo = TnWatchApp.repo(this)
        setContent { WearApp(repo) }
    }

    override fun onResume() {
        super.onResume()
        TnWatchApp.repo(this).refresh()
    }
}
