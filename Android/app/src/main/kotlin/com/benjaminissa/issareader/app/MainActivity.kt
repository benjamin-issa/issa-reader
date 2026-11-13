package com.benjaminissa.issareader.app

import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.benjaminissa.issareader.app.ui.shell.AppEnvironment
import com.benjaminissa.issareader.app.ui.shell.IssaRoot
import com.benjaminissa.issareader.ui.IssaTheme
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.net.URI

/**
 * The one window. It hands the graph what only an activity has — the Auth
 * Tab's result launcher, the window's keep-screen-on flag, the accessibility
 * announcer — and the links it is opened with: `issareader://book/<uuid>`
 * (the widget, a shortcut) and `issareader://continue`.
 *
 * Its content is `IssaRoot` in the app's theme, edge to edge: the phase's
 * screen, the tabs, and the reader over them.
 */
class MainActivity : ComponentActivity() {
    private val graph: AppGraph get() = (application as IssaApplication).graph

    override fun onCreate(savedInstanceState: Bundle?) {
        // Fixed for the activity's life: turning E-Ink mode on or off restarts
        // it, since a composition's motion is set when it is created.
        val eink = graph.settings.einkMode
        if (eink) enableEdgeToEdge(EInkBars, EInkBars) else enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (eink) window.setBackgroundDrawable(ColorDrawable(Color.WHITE))
        // Registered while the activity is being created, as the launcher requires.
        graph.authTab.attach(this)
        graph.app.announce = { window.decorView.announceForAccessibility(it) }
        // Once: a restart brings the same intent back, and the book it named
        // would open again over wherever the reader had got to.
        if (savedInstanceState == null) handle(intent)
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
        lifecycleScope.launch {
            snapshotFlow { graph.settings.einkMode }.first { it != eink }
            recreate()
        }
        val environment = AppEnvironment.from(graph)
        setContent(parent = if (eink) motionlessComposition() else null) {
            IssaTheme(eink = eink) {
                // Test tags as resource ids, so UI Automator — the live check
                // driving the real app — finds what Swift's identifiers name.
                Box(Modifier.semantics { testTagsAsResourceId = true }) {
                    IssaRoot(environment)
                }
            }
        }
    }

    /** The clipboard can be read only while the window has focus: where a sensitive copy that could not be cleared is cleared. */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) com.benjaminissa.issareader.app.model.Clipboard.clearExpired(this)
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

/** Dark icons on nothing, whatever the system's appearance: E-Ink mode's paper is white in both. */
private val EInkBars = SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
