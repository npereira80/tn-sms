package com.ikuteam.tnwatch

import android.app.Application
import android.content.Context
import com.ikuteam.tnwatch.config.ConfigStore
import com.ikuteam.tnwatch.data.Repository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

class TnWatchApp : Application() {

    lateinit var repo: Repository
        private set

    override fun onCreate() {
        super.onCreate()
        ConfigStore.load(this)
        repo = Repository(applicationContext)
        repo.configure(ConfigStore.state.value)

        // Reconfigure whenever the phone provisions new credentials.
        CoroutineScope(SupervisorJob() + Dispatchers.Main).launch {
            ConfigStore.state.drop(1).collect { repo.configure(it) }
        }
    }

    companion object {
        fun repo(context: Context): Repository =
            (context.applicationContext as TnWatchApp).repo
    }
}
