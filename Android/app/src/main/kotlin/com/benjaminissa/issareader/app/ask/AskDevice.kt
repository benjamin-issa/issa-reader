package com.benjaminissa.issareader.app.ask

import com.benjaminissa.issareader.app.local.LocalDevice
import com.benjaminissa.issareader.ask.AskFailure

/**
 * "phone" or "tablet" — the machine the reader is holding.
 *
 * Every sentence this feature shows names it, because "this device" reads as a
 * support article and the promise being made is about *their* machine. The
 * same noun the local books' copy uses ([LocalDevice]), set at launch from the
 * screen's smallest width: Swift's `AskDevice.noun`, which says "iPad" on an
 * iPad.
 */
object AskDevice {
    val noun: String get() = LocalDevice.noun
}

/**
 * The feature's sentences about whether this machine can answer, in one place
 * so the sheet and the settings section cannot come to word the same fact
 * differently. Swift's, with Apple Intelligence as Gemini Nano.
 */
object AskCopy {
    /** What the model is called to a reader. */
    const val ASSISTANT = AskFailure.ASSISTANT

    /**
     * The promise under the switch: where the answer is worked out, and how
     * far it can be trusted. The iPhone's available-state footer, and — on
     * Android — the footer while the switch is off as well: nothing can be
     * asked of ML Kit until the reader turns Ask on, so there is nothing yet
     * to say about this phone in particular.
     */
    fun promise(noun: String = AskDevice.noun): String =
        "$ASSISTANT answers on this $noun; nothing leaves it. Issa Reader tries to limit the answer to only the parts " +
            "of the book you have read, but can't guarantee it, and the model can produce incorrect answers."

    /** The system is downloading the model on its own. The iPhone's `modelDownloading` sentence. */
    fun stillDownloading(noun: String = AskDevice.noun): String =
        "$ASSISTANT is still downloading its model to this $noun. Asking will work once it finishes."

    /** The app's own download of the model, with how far it has got when ML Kit has said. */
    fun downloading(fraction: Double?, noun: String = AskDevice.noun): String {
        val sentence = "$ASSISTANT is downloading to this $noun…"
        val percent = fraction?.takeIf { !it.isNaN() }?.coerceIn(0.0, 1.0)?.let { (it * 100).toInt() } ?: return sentence
        return "$sentence $percent%"
    }

    /** ML Kit's `NEEDS_SYSTEM_UPDATE`: the system's AI service is too old. The reader's to fix. */
    fun needsSystemUpdate(noun: String = AskDevice.noun): String =
        "$ASSISTANT needs a system update on this $noun before it can answer. Check for updates in Settings, then come back."

    /** This hardware will never run it. */
    fun unsupported(noun: String = AskDevice.noun): String =
        "This $noun can't run $ASSISTANT, so asking isn't available here."

    /**
     * The sheet, opened with the switch off. The iPhone's "Apple Intelligence
     * is turned off" sentence, about the app's own switch: on Android that is
     * the one thing between the reader and an answer.
     */
    const val TURNED_OFF = "Ask about your book is turned off. Turn it on in Settings, then come back."
}
