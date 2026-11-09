package com.benjaminissa.issareader.app.ask

import com.benjaminissa.issareader.ask.AskFailure

/**
 * What the Ask section of Settings shows: whether the switch is on, and the
 * one honest sentence under it.
 *
 * Several states rather than "on" and "off", for the reason the iPhone has
 * four sections: only some of the ways this can fail to work are the reader's
 * to fix, and collapsing them into "unavailable" is how somebody comes to
 * believe the feature is broken when it is three minutes from working.
 *
 * Unlike the iPhone's, the switch is always there. The iPhone reads Apple
 * Intelligence's availability as the screen opens; here nothing may be asked
 * of ML Kit until the reader turns Ask on, so the switch is the question —
 * and when the answer is "this phone can't", the switch goes back off with the
 * reason under it rather than vanishing, so the reader can find it again.
 */
sealed interface AskSettingsState {
    /** Whether the switch is drawn on. */
    val isOn: Boolean

    /** The sentence under the section. */
    fun footer(noun: String = AskDevice.noun): String

    /** Off, and nothing has been asked of ML Kit: the promise, neutrally. */
    data object Off : AskSettingsState {
        override val isOn: Boolean get() = false
        override fun footer(noun: String): String = AskCopy.promise(noun)
    }

    /** On, and asking works — or is being checked, which will usually say it does. */
    data object On : AskSettingsState {
        override val isOn: Boolean get() = true
        override fun footer(noun: String): String = AskCopy.promise(noun)
    }

    /** On, and the app is downloading the model: [fraction] is null until ML Kit says how much there is. */
    data class Downloading(val fraction: Double?) : AskSettingsState {
        override val isOn: Boolean get() = true
        override fun footer(noun: String): String = AskCopy.downloading(fraction, noun)
    }

    /** On, and the system is downloading the model on its own. */
    data object SystemDownloading : AskSettingsState {
        override val isOn: Boolean get() = true
        override fun footer(noun: String): String = AskCopy.stillDownloading(noun)
    }

    /** Turned on, and found to need a system update: back off, with the way forward. */
    data object NeedsSystemUpdate : AskSettingsState {
        override val isOn: Boolean get() = false
        override fun footer(noun: String): String = AskCopy.needsSystemUpdate(noun)
    }

    /** Turned on, and found to be a phone that will never run the model: back off, and said so. */
    data object Unsupported : AskSettingsState {
        override val isOn: Boolean get() = false
        override fun footer(noun: String): String = AskCopy.unsupported(noun)
    }

    /** The model's download stopped: back off, with what to do about it. Turning it on again retries. */
    data class DownloadFailed(val failure: AskFailure) : AskSettingsState {
        override val isOn: Boolean get() = false
        override fun footer(noun: String): String = failure.message(noun)
    }
}
