package com.benjaminissa.issareader.app.ask

import com.benjaminissa.issareader.app.local.LocalDevice
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ask.ProviderKind

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
     *
     * "Your questions … don't leave it" rather than the iPhone's "nothing
     * leaves it": ML Kit reports its own diagnostics to Google once Ask is on
     * (PRIVACY-ANDROID.md), so the sentence says exactly what stays.
     */
    fun promise(noun: String = AskDevice.noun): String =
        "Your questions are answered on this $noun, and they don't leave it. Answers try to stay within what " +
            "you've read, but they can contain spoilers and mistakes."

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

    /**
     * The Settings switch's own label, which the sentence below names. One
     * string, so a rename in Settings cannot leave the sheet pointing at a
     * switch that no longer exists.
     */
    const val SWITCH_TITLE = "Ask about your book"

    /**
     * How to take the button away again, said wherever the sheet explains why
     * it cannot answer yet. Swift's `AskDevice.hideButtonSentence`. Ask is off
     * until the reader turns it on here, so only a reader who did sees it, and
     * one whose phone is not ready yet needs the way out as much as the way on.
     */
    const val HIDE_BUTTON = "To hide the button, turn off $SWITCH_TITLE in Settings."

    /** What the sheet says while the model is downloading or downloadable: [stillDownloading] and the way out. */
    fun sheetStillDownloading(noun: String = AskDevice.noun): String = "${stillDownloading(noun)} $HIDE_BUTTON"

    /** What the sheet says when the system needs an update: [needsSystemUpdate] and the way out. */
    fun sheetNeedsSystemUpdate(noun: String = AskDevice.noun): String = "${needsSystemUpdate(noun)} $HIDE_BUTTON"

    /** This hardware will never run it. */
    fun unsupported(noun: String = AskDevice.noun): String =
        "This $noun can't run $ASSISTANT, so asking isn't available here."

    /**
     * The footer on a phone that cannot run Gemini Nano, where a reader's own
     * key is the only thing that answers. Swift's, about Apple Intelligence.
     */
    fun keysOnly(providers: List<ProviderKind>, noun: String = AskDevice.noun): String =
        "This $noun can't run $ASSISTANT, so your questions and the text of the book up to where you've read are " +
            "sent to ${names(providers)}, using your own key. Keys are in Settings › Advanced. Answers can contain " +
            "spoilers and mistakes."

    /** Said after the footer whenever a key is registered: where its questions go. */
    fun providerSentence(providers: List<ProviderKind>): String {
        if (providers.isEmpty()) return ""
        return " Questions you send with your own key go to ${names(providers)}, with the text of the book up to " +
            "where you've read. Keys are in Settings › Advanced."
    }

    /** "Anthropic", "Anthropic and OpenAI": `ListFormatter`'s English. */
    private fun names(providers: List<ProviderKind>): String {
        val names = providers.map { it.displayName }
        return if (names.size <= 2) names.joinToString(" and ") else names.dropLast(1).joinToString(", ") + " and " + names.last()
    }

    /**
     * The sheet, opened with the switch off. The iPhone's "Apple Intelligence
     * is turned off" sentence, about the app's own switch: on Android that is
     * the one thing between the reader and an answer.
     */
    const val TURNED_OFF = "Ask about your book is turned off. Turn it on in Settings, then come back."
}
