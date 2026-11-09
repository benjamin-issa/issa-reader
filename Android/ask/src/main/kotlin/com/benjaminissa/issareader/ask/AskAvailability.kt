package com.benjaminissa.issareader.ask

/**
 * Whether this machine can answer a question at all, and if not, why.
 *
 * Several distinct answers rather than a Boolean, because the settings screen
 * says something different for each and only some of them are the reader's to
 * fix: an ineligible device is a dead end, a model that can be downloaded is a
 * button, a model still downloading is a matter of waiting, and a system that
 * is too old is a trip to the system's updates. Collapsing them into
 * "unavailable" is how a reader ends up believing the feature is broken when
 * it is three minutes from working.
 *
 * Read on Android by `GeminiNanoAvailability.current()` in `:ask-android`,
 * which maps ML Kit's feature status onto these. [APPLE_INTELLIGENCE_OFF] and
 * [UNSUPPORTED_ON_THIS_PLATFORM] are kept so the two clients' settings copy
 * can be written against one list; Android never produces either.
 */
enum class AskAvailability {
    AVAILABLE,

    /** Apple's: the device is eligible but Apple Intelligence has not been turned on. Never on Android. */
    APPLE_INTELLIGENCE_OFF,

    /** Eligible, and the model is coming down. */
    MODEL_DOWNLOADING,

    /**
     * Eligible, and the model can be downloaded but has not been: ML Kit's
     * `DOWNLOADABLE`. Nothing downloads it on its own, so the app offers to.
     */
    MODEL_DOWNLOADABLE,

    /**
     * The device could run the model, but its AI service needs a system update
     * first: ML Kit's `NEEDS_SYSTEM_UPDATE` and `AICORE_INCOMPATIBLE`.
     */
    NEEDS_SYSTEM_UPDATE,

    /** This hardware will never run it. */
    UNSUPPORTED_DEVICE,

    /** Apple TV: nothing to ask either way. Never on Android. */
    UNSUPPORTED_ON_THIS_PLATFORM,
    ;

    /**
     * Whether a question can be asked right now. A model still downloading or
     * not yet downloaded is *not* ready: the toggle stays usable so the reader
     * can turn the feature on and have it work later, but a question asked now
     * fails.
     */
    val isReady: Boolean get() = this == AVAILABLE
}
