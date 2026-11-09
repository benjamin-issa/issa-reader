package com.benjaminissa.issareader.ask.android

import android.content.Context
import com.google.mlkit.common.MlKit

/**
 * ML Kit's start, made by hand, once, and only when the reader has asked for
 * the feature that needs it.
 *
 * ML Kit normally starts itself: `com.google.mlkit:common` declares a content
 * provider (`MlKitInitProvider`) that runs at every process start, before any
 * of the app's code, and from its first call ML Kit sends Google diagnostics —
 * a device identifier, the model, the app's version, timings and error codes.
 * The reader decided that with Ask off nothing goes to Google, so the app's
 * manifest removes that provider, and this is the one place ML Kit is started
 * instead: immediately before the first call into this module, which the app
 * makes only once Ask has been turned on.
 *
 * Guarded here rather than trusted to the framework. `MlKit.initialize` is
 * not idempotent — a second call fails its own precondition with
 * "MlKitContext is already initialized" (common 18.11.0); the idempotent form,
 * `MlKitContext.initializeIfNeeded`, is in ML Kit's `sdkinternal` package and
 * not the app's to call.
 */
object MlKitStartup {
    private val lock = Any()

    @Volatile private var started = false

    /** Whether ML Kit has been started in this process. For the tests that prove it has not. */
    val isStarted: Boolean get() = started

    /** Starts ML Kit with the application's context, the first time; does nothing after. */
    fun ensureStarted(context: Context) {
        if (started) return
        synchronized(lock) {
            if (started) return
            try {
                MlKit.initialize(context.applicationContext ?: context)
            } catch (_: IllegalStateException) {
                // Something else in the process started it first: started
                // either way, which is all this is for.
            }
            started = true
        }
    }
}
