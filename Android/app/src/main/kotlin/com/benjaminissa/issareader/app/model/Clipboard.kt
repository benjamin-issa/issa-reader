package com.benjaminissa.issareader.app.model

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import java.util.UUID

/**
 * Copying text, spelled once rather than at every call site.
 *
 * Most of what this copies is sensitive and short-lived by nature: a device
 * sign-in code, which is a live credential, and the diagnostics log, which
 * carries the server's hostname and the title of every book opened in the
 * last six hours. Neither needs to outlive the paste.
 *
 * Android has no expiry date on a clip, so a value copied with a lifetime is
 * marked sensitive (`EXTRA_IS_SENSITIVE`, which keeps it out of the clipboard
 * preview and history) and taken off the clipboard when its lifetime ends —
 * only if it is still *this copy* there (by an id in the clip, not by its text),
 * so a later copy — the reader's own, or the same text copied again — is never
 * cleared.
 */
object Clipboard {
    /** How long a copied value stays on the clipboard by default, in seconds. */
    const val DEFAULT_LIFETIME: Double = 2.0 * 60

    /** The clip description extra that names one copy. */
    const val COPY_ID_KEY: String = "com.benjaminissa.issareader.COPY_ID"

    /**
     * @param lifetime null for a value the reader means to keep — an answer
     *   about a book, copied into their own notes perhaps an hour later.
     */
    fun copy(context: Context, text: String, lifetime: Double? = DEFAULT_LIFETIME) {
        val manager = context.getSystemService(ClipboardManager::class.java) ?: return
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
        manager.setPrimaryClip(clip)
        lifetime ?: return
        Handler(Looper.getMainLooper()).postDelayed({
            val current = manager.primaryClip
            val still = current != null && current.itemCount == 1 &&
                current.description.extras?.getString(COPY_ID_KEY) == id
            if (!still) return@postDelayed
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) manager.clearPrimaryClip()
        }, (lifetime * 1000).toLong())
    }
}
