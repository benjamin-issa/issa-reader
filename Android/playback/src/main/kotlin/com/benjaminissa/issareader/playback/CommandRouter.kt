package com.benjaminissa.issareader.playback

/**
 * Routes every external control through one place.
 *
 * Swift's `RemoteCommandCenter`, with `MPRemoteCommandCenter` taken out: the
 * decisions it made — which commands exist on which surface, which action a
 * control means there, what the now-playing entry says — are kept here as
 * plain state and functions, and the Android media session calls them. The
 * session's callback hands each command to the entry points below
 * ([play], [skipForward], [nextTrack], …); the session reads [transport] to
 * decide which buttons to offer, and rebuilds them when [onTransportChange]
 * fires.
 *
 * The lock screen, headphone buttons, the car's transport and its
 * steering-wheel controls all arrive as media-session commands. Funnelling them
 * here is what makes the per-surface remapping possible: the binding is
 * consulted at the moment a command fires, so changing it takes effect
 * everywhere without re-registering anything.
 *
 * The mapping from hardware to command is worth stating plainly, because it is
 * the part people get wrong: a steering wheel's `»` and `«` are delivered as
 * next/previous **track**, not as skip commands. Offering only skip commands
 * leaves the wheel buttons dead. Offering *both* makes the system draw the
 * track buttons and hide the interval skips. So the track pair is offered per
 * surface, from the bindings — not on the phone, where nothing is bound to the
 * wheel and the lock screen should read `⏪15` / `⏩30`, and in the car, where
 * the wheel is the control that matters.
 *
 * Main-thread-only, as the Swift type is `@MainActor`.
 */
class CommandRouter(commandMap: CommandMap = CommandMap()) {
    /**
     * What the media session should offer while this router is active.
     *
     * Skip intervals must be declared, or the system draws no skip buttons;
     * [usesTrackCommands] is the switch between the two transports the system
     * will draw.
     */
    data class Transport(
        val skipForwardInterval: Double,
        val skipBackwardInterval: Double,
        /**
         * Whether next/previous track are offered. Offered, the system shows the
         * track buttons and hides the interval skips; not offered, it shows the
         * skips. Offering them unconditionally is what made every remote control
         * on the phone jump a whole chapter, and made the lock screen advertise
         * that as the only thing it could do.
         */
        val usesTrackCommands: Boolean,
        /** The speeds the system's own speed control may choose from. */
        val supportedRates: List<Double> = PlaybackRate.ladder,
    )

    /** What the now-playing entry says — the lock screen, the notification and the car. */
    data class NowPlaying(
        val title: String,
        /** The book's byline. */
        val artist: String,
        /** The chapter, when there is one worth naming. */
        val album: String?,
        val elapsed: Double,
        val duration: Double,
        /** Without an explicit rate the lock screen shows a frozen scrubber. */
        val rate: Float,
        val defaultRate: Float = 1f,
    ) {
        val isPlaying: Boolean get() = rate > 0
    }

    var commandMap: CommandMap = commandMap

    /**
     * Which surface a command should be interpreted as coming from.
     *
     * Re-registers on change, because which commands exist at all depends on
     * it: connecting to a car brings the wheel's track buttons into being and
     * disconnecting takes them away again. Registering once at launch left the
     * car with whichever set the sofa happened to need.
     *
     * Only [ControlSurface.CAR] and [ControlSurface.PHONE] are ever assigned
     * here — the Android Auto bridge is the one caller. [ControlSurface.HEADPHONES]
     * is not assigned but *inferred*, per control, from the audio route; see
     * [surface].
     */
    var activeSurface: ControlSurface = ControlSurface.PHONE
        set(value) {
            if (field == value) return
            field = value
            activate()
        }

    /**
     * Whether a headphone-class device is the current output route — wired
     * headphones, a headset, Bluetooth or USB headphones, a hearing aid.
     *
     * Reported by the session layer, which watches the audio devices. A plain
     * Bluetooth car head unit is deliberately not counted where it can be told
     * apart: its buttons keep resolving against the phone surface. The
     * headphones tab is for the things worn on a head. Re-registers when it
     * moves the wheel to another surface — whether the track commands exist at
     * all depends on it, exactly as it does for the car.
     */
    var headphonesRouted: Boolean = false
        set(value) {
            field = value
            if (transport != null && value != headphonesWereRouted) activate()
        }

    /** What [headphonesRouted] read at the last registration. */
    private var headphonesWereRouted = false

    var onAction: ((PlaybackAction) -> Unit)? = null

    /** Absolute seek in seconds, from the lock-screen or car scrubber. */
    var onSeek: ((Double) -> Unit)? = null

    /** Rate chosen from the system's own speed control. */
    var onRateChange: ((Float) -> Unit)? = null

    /** Called whenever [transport] changes, so the session can rebuild its commands. */
    var onTransportChange: ((Transport?) -> Unit)? = null

    /** What is offered now, or null while nothing is registered. */
    var transport: Transport? = null
        private set

    /** (Re)registers everything against the current map and surface. */
    fun activate() {
        tearDown()
        headphonesWereRouted = headphonesRouted
        // Against the surface the wheel belongs to right now — with headphones
        // routed that is HEADPHONES, so a binding made on that tab is what
        // brings the track commands into being.
        val wheelSurface = surface(PlaybackControl.WHEEL_NEXT, activeSurface, headphonesWereRouted)
        val offered = Transport(
            skipForwardInterval = commandMap.skipForwardInterval,
            skipBackwardInterval = commandMap.skipBackwardInterval,
            usesTrackCommands = commandMap.usesTrackCommands(wheelSurface),
        )
        transport = offered
        onTransportChange?.invoke(offered)
    }

    /** Stops answering: every entry point does nothing until [activate]. */
    fun tearDown() {
        if (transport == null) return
        transport = null
        onTransportChange?.invoke(null)
    }

    // What the media session calls.

    /**
     * Play and pause are discrete on purpose, never the toggle. The system
     * decides which button to draw from the published rate, and during a
     * buffering stall — or the instant after play(), while the engine is still
     * waiting to start — that rate is 0 while `isPlaying` is true. The system
     * draws ▶, the listener taps it, and a toggled play/pause *paused* the
     * stalled book. The system already says which one it means; believe it.
     */
    fun play() = dispatch(PlaybackAction.PLAY)

    fun pause() = dispatch(PlaybackAction.PAUSE)

    fun togglePlayPause() = dispatch(PlaybackAction.PLAY_PAUSE)

    /**
     * The system's skip-forward command: the tap control.
     *
     * @param from the surface the command came from, where the session can
     *   tell — Android names the controller that sent each command, which iOS
     *   never did: Android Auto is the car, the media notification and the
     *   app's own controller are the phone. Null for a command whose sender
     *   says nothing about where it was pressed — a hardware media key, a
     *   Bluetooth remote — which is inferred as [surface] infers it.
     */
    fun skipForward(from: ControlSurface? = null) = fire(PlaybackControl.TAP_FORWARD, from)

    fun skipBackward(from: ControlSurface? = null) = fire(PlaybackControl.TAP_BACKWARD, from)

    /**
     * Next track — a head unit's, a steering wheel's `»`, headphones' double
     * press. Only answered while this surface binds the wheel; otherwise the
     * command is not offered at all.
     *
     * @param from as for [skipForward]. A surface that binds the wheel is
     *   answered by its own binding even while the transport on offer was
     *   drawn for another — the car's wheel is the car's before the phone has
     *   heard it connect. One that binds nothing to the wheel resolves against
     *   the surface the track buttons were drawn for, because a button on
     *   screen that does nothing when pressed is worse than one that does what
     *   it does everywhere else.
     */
    fun nextTrack(from: ControlSurface? = null) {
        if (offersTrackCommands(from)) fire(PlaybackControl.WHEEL_NEXT, trackSurface(from))
    }

    fun previousTrack(from: ControlSurface? = null) {
        if (offersTrackCommands(from)) fire(PlaybackControl.WHEEL_PREVIOUS, trackSurface(from))
    }

    /**
     * Whether next/previous track mean anything for a command from [from]:
     * offered by the transport, or bound on that surface's own wheel.
     *
     * What a hardware key decoder asks before it turns a headset's double
     * press into a track command or, as iOS does when the track pair is not
     * registered, into a skip.
     */
    fun offersTrackCommands(from: ControlSurface? = null): Boolean {
        if (transport == null) return false
        if (transport?.usesTrackCommands == true) return true
        return from != null && commandMap.usesTrackCommands(from)
    }

    /** The surface a track command resolves against: its own, when it binds the wheel. */
    private fun trackSurface(from: ControlSurface?): ControlSurface? =
        from?.takeIf { commandMap.usesTrackCommands(it) }

    /**
     * A scrubber drag: seconds on whatever span the now-playing entry
     * published. The caller turns it back into a book position through
     * [PlaybackProgress.bookProgressForSeconds].
     */
    fun seekTo(seconds: Double) {
        if (transport == null) return
        onSeek?.invoke(seconds)
    }

    /** A speed from the system's own control, which the caller still clamps. */
    fun changeRate(rate: Float) {
        if (transport == null) return
        onRateChange?.invoke(rate)
    }

    private fun dispatch(action: PlaybackAction) {
        if (transport == null) return
        onAction?.invoke(action)
    }

    private fun fire(control: PlaybackControl, from: ControlSurface? = null) {
        if (transport == null) return
        val surface = from ?: surface(control, activeSurface, headphonesRouted)
        val action = commandMap.action(control, surface)
        if (action == PlaybackAction.NONE) return
        onAction?.invoke(action)
    }

    companion object {
        /**
         * Which surface a control's binding resolves against right now.
         *
         * The session never says where a command physically came from, so this
         * is inference, stated plainly. In the car, everything belongs to the
         * car. Otherwise the *wheel* controls are attributed to headphones while
         * a headphone-class device is the audio route — next/previous track is
         * how headphones' double- and triple-press arrive — and the tap controls
         * stay with the phone, because the skip commands only ever come from a
         * screen; no headphone sends one. Before this, nothing anywhere set
         * HEADPHONES, so every binding made on that settings tab was silently
         * discarded and the wheel resolved against the phone instead.
         */
        fun surface(control: PlaybackControl, active: ControlSurface, headphonesRouted: Boolean): ControlSurface {
            if (active == ControlSurface.CAR) return ControlSurface.CAR
            return when (control) {
                PlaybackControl.WHEEL_NEXT, PlaybackControl.WHEEL_PREVIOUS ->
                    if (headphonesRouted) ControlSurface.HEADPHONES else active
                else -> active
            }
        }

        /**
         * What is playing, for the lock screen and the car: the book as the
         * title, the byline as the artist, and the chapter — when it has a name
         * worth showing — as the album.
         */
        fun nowPlaying(
            title: String,
            author: String,
            chapter: String?,
            elapsed: Double,
            duration: Double,
            rate: Float,
        ): NowPlaying = NowPlaying(
            title = title,
            artist = author,
            album = chapter,
            elapsed = elapsed,
            duration = duration,
            rate = rate,
        )
    }
}
