package com.jarviscopilot.mobile

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.annotation.NonNull
import com.jarviscopilot.mobile.skills.SkillChannels
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(@NonNull engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        SkillChannels.registerAll(this, engine)

        // Start the foreground bridge service so the WS stays alive
        // even when the app is backgrounded. (Skipped on Android 14+
        // for the first 5 seconds of process launch — startForeground
        // call inside the service handles the FGS type requirement.)
        val intent = Intent(this, BridgeService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDeepLink(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleDeepLink(intent)
    }

    private fun handleDeepLink(intent: Intent?) {
        val uri: Uri = intent?.data ?: return
        if (uri.scheme != "jarviscopilot") return
        // Defer until Flutter is up. We post to the main thread so the
        // engine has a chance to attach.
        window?.decorView?.post {
            try {
                val ch = MethodChannel(
                    flutterEngine!!.dartExecutor.binaryMessenger,
                    "jarviscopilot/pair"
                )
                ch.invokeMethod("openPair", mapOf("url" to uri.toString()))
            } catch (_: Throwable) {
                // Engine not ready yet; the URL will be picked up next
                // time the user opens a Pair page manually.
            }
        }
    }
}
