package com.ikuteam.tnwatch

import android.app.Application
import android.content.Context
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import com.ikuteam.tnwatch.config.ConfigStore
import com.ikuteam.tnwatch.data.Repository
import com.ikuteam.tnwatch.net.Http
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
        installCrashLogger()
        // Needed so a failed request can be relayed through the phone.
        Http.appContext = applicationContext
        ConfigStore.load(this)
        repo = Repository(applicationContext)
        repo.configure(ConfigStore.state.value)

        // Reconfigure whenever the phone provisions new credentials.
        CoroutineScope(SupervisorJob() + Dispatchers.Main).launch {
            ConfigStore.state.drop(1).collect { repo.configure(it) }
        }
    }

    /**
     * Persists any uncaught exception to files/crash.txt, so a crash can be read
     * without a working logcat:
     *   adb -s <watch> shell run-as com.bluebubbles.messaging cat files/crash.txt
     */
    private fun installCrashLogger() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                Log.e("TnWatch", "FATAL on ${thread.name}", throwable)
                val sw = StringWriter()
                throwable.printStackTrace(PrintWriter(sw))
                File(filesDir, "crash.txt").writeText(
                    "when=${System.currentTimeMillis()}\nthread=${thread.name}\n\n$sw",
                )
            } catch (_: Throwable) {
                // never mask the original crash
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    companion object {
        fun repo(context: Context): Repository =
            (context.applicationContext as TnWatchApp).repo
    }
}
