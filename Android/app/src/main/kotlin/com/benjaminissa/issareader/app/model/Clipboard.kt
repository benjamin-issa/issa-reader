package com.benjaminissa.issareader.app.model

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle

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
 * only if it is still the clip there, so the reader's own later copy is never
 * cleared.
 */
object Clipboard {
    /** How long a copied value stays on the clipboard by default, in seconds. */
    const val DEFAULT_LIFETIME: Double = 2.0 * 60

    /**
     * @param lifetime null for a value the reader means to keep — an answer
     *   about a book, copied into their own notes perhaps an hour later.
     */
    fun copy(context: Context, text: String, lifetime: Double? = DEFAULT_LIFETIME) {
        val manager = context.getSystemService(ClipboardManager::class.java) ?: return
        val clip = ClipData.newPlainText("Issa Reader", text)
        if (lifetime != null) {
            clip.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            }
        }
        manager.setPrimaryClip(clip)
        lifetime ?: return
        Handler(Looper.getMainLooper()).postDelayed({
            val current = manager.primaryClip
            val still = current != null && current.itemCount == 1 &&
                current.getItemAt(0).text?.toString() == text
            if (!still) return@postDelayed
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) manager.clearPrimaryClip()
        }, (lifetime * 1000).toLong())
    }
}
