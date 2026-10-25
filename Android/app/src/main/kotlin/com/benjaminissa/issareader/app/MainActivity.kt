package com.benjaminissa.issareader.app

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch
import java.net.URI

/**
 * The one window. It hands the graph what only an activity has — the Auth
 * Tab's result launcher, the window's keep-screen-on flag, the accessibility
 * announcer — and the links it is opened with: `issareader://book/<uuid>`
 * (the widget, a shortcut) and `issareader://continue`.
 *
 * The screens are the UI port's; until they land this draws the app's ground.
 */
class MainActivity : ComponentActivity() {
    private val graph: AppGraph get() = (application as IssaApplication).graph

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        // Registered while the activity is being created, as the launcher requires.
        graph.authTab.attach(this)
        graph.app.announce = { window.decorView.announceForAccessibility(it) }
        handle(intent)
        // The display held awake while a book is open: one flag for the
        // window, decided by the model.
        lifecycleScope.launch {
            snapshotFlow { graph.app.screenAwake.isHeld }.collect { held ->
                if (held) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            }
        }
        // The token going stale while the app is in use.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) { graph.app.watchForExpiry() }
        }
        setContent {
            Box(Modifier.fillMaxSize().background(Color(0xFFEFE8DC)))
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        val data = intent?.data ?: return
        val url = runCatching { URI(data.toString()) }.getOrNull() ?: return
        graph.app.open(url)
    }
}
