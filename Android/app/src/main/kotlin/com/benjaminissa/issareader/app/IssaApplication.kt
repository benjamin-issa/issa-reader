package com.benjaminissa.issareader.app

import android.app.Application
import android.content.ComponentCallbacks2

/**
 * Builds the app's graph as the process starts, however it was started — the
 * launcher, a widget, a download worker resuming, or Android Auto binding the
 * media service with no activity at all.
 *
 * Open for one reason: the launch test's subclass starts a test WorkManager
 * first, as Android's start-up provider starts the real one before this runs
 * on a phone and Robolectric does not run providers.
 */
open class IssaApplication : Application() {
    lateinit var graph: AppGraph
        private set

    override fun onCreate() {
        super.onCreate()
        graph = AppGraph(this)
        graph.start()
    }

    @Deprecated("Deprecated in Java")
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) graph.trimMemory()
    }
}
