package com.benjaminissa.issareader.app.model

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.SystemClock
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import java.util.UUID

/**
 * Copying text, spelled once rather than at every call site.
 *
 * Some of what this copies is sensitive and short-lived by nature: a device
 * sign-in code, which is a live credential, and the diagnostics log, which
 * carries the server's hostname and the title of every book opened in the
 * last six hours. Those are copied with a lifetime; text the reader copies
 * out of a book, or an answer about one, is theirs and is never expired.
 *
 * Android has no expiry date on a clip, so a value copied with a lifetime is
 * marked sensitive (`EXTRA_IS_SENSITIVE`, a hint that the preview may honour)
 * and taken off the clipboard when its lifetime ends — only if it is still
 * *this copy* there (by an id in the clip, not by its text), so a later copy —
 * the reader's own, or the same text copied again — is never cleared.
 *
 * Android lets only the app in front read the clipboard, and the sign-in code
 * is copied to be carried to a browser, so the timer often fires while the app
 * is not in front and cannot tell whether the clip is still its own. It then
 * keeps the copy as pending, and [clearExpired] settles it the next time the
 * app has the window focus.
 */
object Clipboard {
    /** How long a sensitive value stays on the clipboard, in seconds. */
    const val DEFAULT_LIFETIME: Double = 2.0 * 60

    /** The clip description extra that names one copy. */
    const val COPY_ID_KEY: String = "com.benjaminissa.issareader.COPY_ID"

    /** A copy that is to be cleared, and when. */
    private class Pending(val id: String, val deadline: Long)

    private var pending: Pending? = null

    /** How the clip is read; a test replaces it with one that cannot, as the system does without focus. */
    internal var read: (ClipboardManager) -> ClipData? = { it.primaryClip }

    /** Whether the system says the clipboard holds a clip; without focus it says no, as it does for an empty one. */
    internal var holdsClip: (ClipboardManager) -> Boolean = { it.hasPrimaryClip() }

    /** Whether a sensitive copy is waiting to be cleared. */
    internal val isPending: Boolean get() = pending != null

    /** Elapsed milliseconds; a test moves it. */
    internal var clock: () -> Long = SystemClock::elapsedRealtime

    /**
     * @param lifetime null for a value the reader means to keep: the passage
     *   they copied from a book, an answer about one, pasted into their own
     *   notes perhaps an hour later.
     * @return whether the system took the copy; a value too large for it is
     *   refused rather than crashing the app.
     */
    fun copy(context: Context, text: String, lifetime: Double? = null): Boolean {
        val manager = context.getSystemService(ClipboardManager::class.java) ?: return false
        val clip = ClipData.newPlainText("Issa Reader", text)
        // Each copy carries its own id, so a timer can tell its own clip from a
        // later copy of the very same text, which it must not clear early.
        val id = UUID.randomUUID().toString()
        if (lifetime != null) {
            clip.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                putString(COPY_ID_KEY, id)
            }
        }
        // A new copy ends whatever was waiting to be cleared: it replaced it.
        pending = null
        try {
            manager.setPrimaryClip(clip)
        } catch (failure: RuntimeException) {
            IssaLog.warning("copy to the clipboard failed", mapOf("error" to failure.javaClass.simpleName, "length" to text.length.toString()))
            return false
        }
        lifetime ?: return true
        pending = Pending(id, clock() + (lifetime * 1000).toLong())
        Handler(Looper.getMainLooper()).postDelayed({ clearExpired(context) }, (lifetime * 1000).toLong())
        return true
    }

    /**
     * Takes a sensitive copy off the clipboard once its lifetime is over, if
     * the clipboard still holds it. When the clip cannot be read now, because
     * the app is not in front, the copy stays pending and this is tried again:
     * call it, with [focused] true, when the window gains focus; only then does
     * an empty clipboard settle the copy.
     */
    fun clearExpired(context: Context, focused: Boolean = false) {
        val waiting = pending ?: return
        if (clock() < waiting.deadline) return
        val manager = context.getSystemService(ClipboardManager::class.java) ?: return
        // Without the focus Android says there is no clip, exactly as it does
        // for an empty clipboard, so only with the focus is "no clip" an answer.
        if (!holdsClip(manager)) {
            if (focused) pending = null
            return
        }
        val current = read(manager) ?: return
        pending = null
        val still = current.itemCount == 1 && current.description.extras?.getString(COPY_ID_KEY) == waiting.id
        if (still) manager.clearPrimaryClip()
    }
}
