import AVFoundation
import Foundation
import IssaCore
import Observation

/// Plays a book's narration.
///
/// `AVPlayer` rather than `AVAudioEngine`: it handles HTTP range requests,
/// gapless queueing and rate changes without hand-rolling a scheduling layer,
/// and `audioTimePitchAlgorithm` gives pitch-corrected speech at high rates,
/// which is the single most-used audiobook feature.
@Observable
@MainActor
public final class AudioPlayer {
    /// Settable inside the module so a test can stand for a playing book
    /// without real audio reaching a real end — see `ReadalongFileEndTests`.
    public internal(set) var isPlaying = false
    /// Seconds into the currently loaded audio file.
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var currentAudioHref: String?

    /// 0...1, used by the sleep timer's fade-out.
    ///
    /// The fade owns this number outright — `NowPlayingController` hands the
    /// timer a closure that writes it every tick — so the per-book level cannot
    /// live here as well. It goes through `gain` instead, and the two are
    /// combined in `applyPlayerVolume`.
    public var volume: Float = 1.0 {
        didSet { applyPlayerVolume() }
    }

    /// This book's level, as a multiplier of the recorded one.
    ///
    /// Separate from `volume` because it must be able to exceed 1, which
    /// `AVPlayer.volume` cannot: a quietly mastered book needs *more* than the
    /// file has, and that gain can only come from the samples themselves. The
    /// value is pushed into the tap here so the real-time thread never has to
    /// ask this actor for it.
    public var gain: Float = 1 {
        didSet {
            // Clamp, then apply the clamped value, in one pass — the same
            // shape, and for the same reason, as `PlaybackSettings.playbackRate`
            // documents at length: this class is `@Observable`, so the property
            // is macro-synthesised and the assignment below *does* re-enter this
            // observer. Writing the clamped value afterwards regardless is what
            // makes the method not depend on knowing that.
            let legal = VolumeTrim.clampedGain(gain)
            if legal != gain { gain = legal }
            gainTap.gain.store(legal, ordering: .relaxed)
            applyPlayerVolume()
        }
    }

    /// What the player is actually set to, for tests. The interesting cases are
    /// the ones where it is *not* `volume`: a stream with no loadable tracks
    /// has no tap, and the quieter half of the trim is then carried here.
    var underlyingVolume: Float { player.volume }

    /// Whether the loaded item's audio genuinely runs through the tap.
    ///
    /// False for anything whose tracks could not be loaded, and the fallback
    /// below depends on it. **Nil until something has been loaded to ask
    /// about**, which is a different answer from "no": a player that has not
    /// reached `load` yet is not a book that cannot be made louder, and a
    /// screen that read the two as one would caption every book for the moment
    /// before its first track resolves.
    ///
    /// Public because it is the only signal a reader has. Without the tap
    /// `applyPlayerVolume` below can only go *down* — `AVPlayer.volume` is
    /// documented 0…1 — so a book set louder plays at "as recorded" with
    /// nothing on screen to say why. That was a 3.5 dB silent loss on the
    /// percentage scale this replaced; with the +8 dB top rung it is an 8 dB
    /// one. `VolumeTrimRow` reads it and says so.
    public private(set) var tapCarriesGain: Bool?

    /// The two levels, resolved into the one number `AVPlayer` accepts.
    ///
    /// With the tap attached the gain is already in the samples, so the fade
    /// multiplies it rather than replacing it. Without the tap the player's own
    /// volume is all there is: `min(gain, 1)` still delivers "quieter", and
    /// "louder" degrades to as-recorded rather than to a value the API would
    /// clip anyway. Nothing loaded yet takes the same branch as no tap, because
    /// there is no tap either way.
    private func applyPlayerVolume() {
        player.volume = tapCarriesGain == true ? volume : volume * Swift.min(gain, 1)
    }

    public var rate: Float = 1.0 {
        didSet {
            // Stopping is always safe; starting waits while a load is still
            // placing its item — see `placementPending`, and the placement
            // restores whatever `rate` is by then.
            if !isPlaying {
                player.rate = 0
            } else if !placementPending {
                player.rate = rate
            }
            // The effective rate, not the requested one. Observers treat a
            // non-zero rate as "playing" — the widget publishes `isPlaying`
            // from exactly this number — so choosing 1.5× on a paused book
            // must not announce that it started.
            notifyRateObservers(isPlaying ? rate : 0)
        }
    }

    /// The rate audio is genuinely playing at, as opposed to the one we asked
    /// for. `isPlaying` is a hand-maintained flag and stays true through a
    /// buffering stall, so publishing it as the Now Playing rate told iOS to
    /// keep advancing a clock that had stopped.
    public var effectiveRate: Float {
        player.timeControlStatus == .playing ? player.rate : 0
    }

    /// Called on every observed time update, so a coordinator can advance the
    /// read-along highlight without polling.
    public var onTimeUpdate: ((TimeInterval) -> Void)?
    /// Everything that wants to know the rate moved.
    ///
    /// A list, not one closure. Two things genuinely need this — the lock
    /// screen, so a play tap is not up to five seconds stale, and the widget,
    /// so a paused book stops claiming to be playing — and a single slot meant
    /// whichever attached second silently replaced the first.
    private var rateObservers: [ObjectIdentifier: (Float) -> Void] = [:]

    /// Registers an observer against an owner.
    ///
    /// Keyed rather than appended: `NowPlayingController.attach` runs every
    /// time the reader appears — a tab switch, a pop back from Contents — and
    /// appending meant one play tap eventually performed a dozen Now Playing
    /// rebuilds, with every closure retained for the life of the player.
    /// Registering twice for the same owner replaces, which is what the call
    /// sites have always assumed.
    public func setRateObserver(for owner: AnyObject, _ observer: @escaping (Float) -> Void) {
        rateObservers[ObjectIdentifier(owner)] = observer
    }

    /// Drops every observer, for a coordinator being torn down.
    public func removeRateObservers() {
        rateObservers.removeAll()
    }

    private func notifyRateObservers(_ rate: Float) {
        for observer in rateObservers.values { observer(rate) }
    }
    public var onFinishedFile: (() -> Void)?

    /// The engine. A variable, because the audio system can die under it:
    /// when iOS restarts its media services — a phone call was enough, on 21
    /// Nov 2026 — the player it had is a shell that takes a rate and makes no
    /// sound, and only a new one plays again. See `rebuildEngine`.
    @ObservationIgnored private var player = AVQueuePlayer()
    /// Which engine `player` is, bumped by every `makeEngine`. Observers
    /// capture it, so a report from an engine already replaced is ignored.
    private(set) var engineGeneration = 0
    /// One tap for the life of the player, attached to every item it loads, so
    /// a chapter change does not drop the book's level.
    private let gainTap = GainTap()
    /// Observer tokens live outside the actor so `deinit` — which is
    /// nonisolated under Swift 6 — can still tear them down.
    private let observers = ObserverTokens()

    /// Fired when the system interrupts playback and again when it is safe to
    /// resume, so the app can decide rather than guess.
    public var onInterruption: ((Bool) -> Void)?
    /// Fired when headphones are unplugged or a Bluetooth device disappears.
    public var onRouteLoss: (() -> Void)?

    public init() {
        Self.configureAudioSession()
        observeSession()
        setUpEngine()
    }

    deinit {
        observers.tearDown()
    }

    /// The settings and observers an engine needs before it plays. Run for
    /// the first engine and for each one `makeEngine` builds, so a rebuilt
    /// engine is the first one again.
    private func setUpEngine() {
        observers.player = player
        player.actionAtItemEnd = .pause
        // Spoken audio at 1.5–3x is unlistenable without pitch correction, and
        // the time-domain algorithm is the one tuned for speech rather than
        // music.
        player.automaticallyWaitsToMinimizeStalling = false
        observeTimeControl()
        observeEngineStatus()
        observeTime(interval: observationInterval)
    }

    /// Replaces the engine with a fresh, empty one.
    ///
    /// The old engine's observers and time observer go first — a time
    /// observer can only be removed from the player it was added to — and it
    /// is emptied before it is dropped, so nothing it says afterwards reaches
    /// this class and nothing it held is kept alive.
    private func makeEngine() {
        observers.removeTimeObserver(from: player)
        observers.removeItemObservers()
        observers.removeEngineObservers()
        player.rate = 0
        player.currentItem?.cancelPendingSeeks()
        player.removeAllItems()
        player = AVQueuePlayer()
        engineGeneration &+= 1
        setUpEngine()
        applyPlayerVolume()
    }

    /// Prepares the session for spoken audio — without taking the audio route.
    ///
    /// `.playback` keeps sound going when the ring switch is silent and when the
    /// screen locks, which is the whole point of an audiobook app; `.spokenAudio`
    /// tells the system this is speech, so it ducks and resumes the way podcasts
    /// do rather than behaving like music. Declaring the category is free, but
    /// `setActive(true)` is what silences whatever else is audible — and this
    /// runs from `init`, which fires when a book is merely *opened*: a
    /// read-along builds its coordinator eagerly, so activating here stopped
    /// the reader's music the moment they tapped an aligned book. Activation
    /// waits for `play()`, the first moment the app intends to make sound.
    static func configureAudioSession() {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        #endif
    }

    /// Takes the audio route. Without an active session, playback is silent on
    /// a device even though the player reports it is running.
    ///
    /// - Returns: false when the system refused to activate it.
    @discardableResult
    static func activateAudioSession() -> Bool {
        #if os(iOS) || os(tvOS)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            return false
        }
        #endif
        return true
    }

    /// Stops, and gives the audio route back so whatever this interrupted can
    /// carry on.
    ///
    /// For the ends of listening — the book running out, the sleep timer
    /// expiring — and for nothing else. The session is non-mixable, so going
    /// active stopped the listener's music, and nothing ever went inactive:
    /// without `.notifyOthersOnDeactivation` the app that was interrupted is
    /// never told it may resume. An ordinary pause keeps the route, as Apple's
    /// own players do, and the hand-off from the car to the reader must too —
    /// the book is still being listened to there.
    public func endSession() {
        pause(reason: .sessionEnded)
        sessionsEnded += 1
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Takes the session for a play. A test seam: the system's answer is what a
    /// call in progress changes, and nothing else can stage it.
    var activateSession: () -> Bool = { AudioPlayer.activateAudioSession() }

    /// How many times `endSession` has run, for tests: the deactivation itself
    /// is a no-op off a device.
    private(set) var sessionsEnded = 0

    /// Called when a rate is *chosen* through `choose(rate:)` — a bound speed
    /// control — so it can be remembered as the listener's speed.
    public var onRateChosen: ((Float) -> Void)?

    /// Sets the rate as the listener's own choice.
    ///
    /// `rate` is also written by things that are not a choice — restoring the
    /// saved speed when a book opens, the hand-off carrying it across — so
    /// persisting from `rate`'s observer would write back what was just read.
    /// The bound speed-up and speed-down actions used to set `rate` and nothing
    /// else, so a speed picked from a steering-wheel or headphone button was
    /// lost at the next book, the next launch, and the car-to-reader hand-off.
    public func choose(rate chosen: Float) {
        rate = chosen
        onRateChosen?(rate)
    }

    /// The system took the audio session: pause, remembering whether the book
    /// was playing so the end of the interruption can carry on.
    ///
    /// - Parameter wasSuspended: the system's report that the interruption
    ///   began because the app was suspended. That one has already ended by the
    ///   time it is delivered and no `.ended` follows, so it is not an
    ///   interruption: nothing is latched and the player is not held back.
    func interruptionBegan(wasSuspended: Bool = false) {
        if wasSuspended {
            // Over before it was heard, so nothing is latched and no
            // interruption is under way. But a player that claimed to be
            // playing has lost its session: it is brought to paused, as the
            // system's pause and not the listener's.
            if isPlaying { stopPlaying(reason: .systemSuspension) }
            return
        }
        // Latched *after* the pause, not before: `pause()` clears it, because
        // an explicit pause during an interruption must not be undone when the
        // interruption ends. Setting it first would have this pause wipe the
        // very flag it is recording.
        //
        // A second `began` before the first has ended — a navigation prompt
        // and then a call — finds the player already paused by the first, and
        // must not record that as the state to go back to: the end would then
        // leave a book the listener was in the middle of silent. A pause the
        // listener makes in between still clears it, through `pause()`.
        let wasPlaying = isPlaying || latchIsLive
        // Not `pause()`: the system's pause is not the listener's, and a start
        // that is opening its file reads a changed `pauseCount` as the
        // listener's last word and never plays. Such a start has `isPlaying`
        // false and no latch, so nothing would resume it either; see
        // `playAfterStart`.
        stopPlaying(reason: .interruption)
        interruptionsBegun &+= 1
        wasPlayingBeforeInterruption = wasPlaying
        // The latch lives from the latest `began`: an interruption that
        // goes on keeps it, and one whose end never came stops being believed.
        latchedAt = wasPlaying ? interruptionClock() : nil
        interruptedAt = interruptionClock()
        onInterruption?(false)
    }

    /// The system gave the session back.
    func interruptionEnded(shouldResume: Bool) {
        let resumes = shouldResume && latchIsLive
        lastInterruptionEndedWithResume = shouldResume
        // Spent, either way. Without clearing it a second `.ended` with no
        // intervening `.began` — which the system does deliver — resumed a book
        // the listener had stopped.
        wasPlayingBeforeInterruption = false
        latchedAt = nil
        // Over before the resume below, so that its `play()` plays.
        interruptedAt = nil
        if resumes {
            #if os(iOS) || os(tvOS)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            play(because: .callEnded)
        }
        onInterruption?(resumes)
    }

    /// Handles the two things that stop audio without the app asking.
    ///
    /// A phone call interrupts; the system says when it is over and whether it
    /// expects playback to resume. Unplugging headphones is a route change, and
    /// the convention — which every audio app is judged against — is to pause
    /// rather than start playing a book out loud in a quiet room.
    private func observeSession() {
        #if os(iOS) || os(tvOS)
        let center = NotificationCenter.default
        observers.interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main,
        ) { [weak self] note in
            // Read the primitives out of the notification here: Notification is
            // not Sendable, so carrying it across the actor boundary is a race.
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            // 1 is `.appWasSuspended` (named by the deprecated reason constant);
            // the older `wasSuspended` flag says the same on earlier systems.
            let rawReason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            let suspendedFlag = (note.userInfo?[AVAudioSessionInterruptionWasSuspendedKey] as? NSNumber)?.boolValue ?? false
            let wasSuspended = rawReason == 1 || suspendedFlag
            MainActor.assumeIsolated {
                guard let self, let rawType,
                      let type = AVAudioSession.InterruptionType(rawValue: rawType)
                else { return }
                switch type {
                case .began:
                    self.interruptionBegan(wasSuspended: wasSuspended)
                case .ended:
                    let options = rawOptions.map(AVAudioSession.InterruptionOptions.init) ?? []
                    self.interruptionEnded(shouldResume: options.contains(.shouldResume))
                @unknown default:
                    break
                }
            }
        }

        // The audio system restarted under the app. Apple's guidance is to set
        // the session up again and to build every AVFoundation object afresh:
        // the player that was there takes a rate and makes no sound. See
        // `mediaServicesWereReset`.
        observers.mediaReset = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.mediaServicesWereReset() }
        }

        observers.route = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main,
        ) { [weak self] note in
            let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let rawReason,
                      AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
                else { return }
                self.pause(reason: .routeLoss)
                self.onRouteLoss?()
            }
        }
        #endif
    }

    /// Whether the interruption arrived mid-playback, so a resume is only
    /// offered to someone who was actually listening.
    private var wasPlayingBeforeInterruption = false
    private var latchedAt: ContinuousClock.Instant?
    /// When the interruption now in progress began, nil between interruptions.
    private var interruptedAt: ContinuousClock.Instant?
    /// How many interruptions have begun, and whether the latest to end said
    /// the book should resume. What a start's token reads; see `beginStart`.
    private var interruptionsBegun = 0
    private var lastInterruptionEndedWithResume = false

    /// Whether the system has the session: an interruption has begun and its
    /// end has not been seen, within the latch's lifetime. The system does not
    /// always deliver an `.ended`, and a play that waited on one for good
    /// would leave the book silent for the listener who asks for it.
    private var isInterrupted: Bool {
        guard let interruptedAt else { return false }
        return interruptionClock() - interruptedAt <= interruptionLatchLifetime
    }

    /// How long after the latest interruption began its end may still resume
    /// the book. The system does not always deliver an `.ended`, and a latch
    /// that never lapsed let a much later, unrelated interruption's end start
    /// the book by itself. An hour, so the end of a long phone call still
    /// resumes. Internal for the tests.
    var interruptionLatchLifetime: Duration = .seconds(3600)
    /// The clock the latch is read against. A test moves its own, so a
    /// loaded machine's slow sleep cannot be mistaken for a long call.
    var interruptionClock: () -> ContinuousClock.Instant = { ContinuousClock.now }

    /// Whether the book was playing when an interruption began, and that
    /// interruption is recent enough to be the one now ending.
    private var latchIsLive: Bool {
        guard wasPlayingBeforeInterruption, let latchedAt else { return false }
        return interruptionClock() - latchedAt <= interruptionLatchLifetime
    }

    /// Coarse cadence, used when nothing is watching the highlight closely.
    static let idleObservationInterval: TimeInterval = 1.0
    /// Fine cadence, used only while a reader is on screen following narration.
    /// Anything faster wakes the CPU for no visible benefit; the display link
    /// interpolates between these.
    static let activeObservationInterval: TimeInterval = 0.20

    /// Switches observation cadence. Called when the reader appears and
    /// disappears, so a screen-off listening session costs a fraction of the
    /// wakeups an always-fine observer would.
    public func setHighFrequencyUpdates(_ enabled: Bool) {
        observationInterval = enabled ? Self.activeObservationInterval : Self.idleObservationInterval
        observeTime(interval: observationInterval)
    }

    /// The cadence asked for last, so a rebuilt engine is observed at it too.
    private var observationInterval = AudioPlayer.idleObservationInterval

    private func observeTime(interval: TimeInterval) {
        observers.removeTimeObserver(from: player)
        let time = CMTime(seconds: interval, preferredTimescale: 600)
        let engine = engineGeneration
        observers.time = player.addPeriodicTimeObserver(forInterval: time, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                // A CMTime is not a Double. This observer is attached to the
                // player, not the item, and it keeps firing across a track
                // change — at which point `removeAllItems()` has left no current
                // item and the player's time is `.invalid`, whose `.seconds` is
                // NaN. Forwarding that poisoned the book clock: it survived
                // every downstream clamp, was published to Now Playing as a
                // non-finite elapsed, and made a skip seek to zero.
                let seconds = time.seconds
                guard time.isValid, seconds.isFinite else { return }
                self.engineTicked(seconds, engine: engine)
            }
        }
    }

    /// One tick of engine `engine`'s clock. Internal so a test can deliver
    /// one at a moment of its choosing.
    func engineTicked(_ seconds: TimeInterval, engine: Int) {
        // Not a tick from an engine already replaced, or from the new one
        // while the rebuild is still putting the book back: its time is the
        // fresh item's first second, and handing that on would jump the
        // read-along highlight to the file's first sentence, turn the page
        // back and tell the sleep timer a chapter had ended.
        guard engine == engineGeneration, !rebuilding else { return }
        currentTime = seconds
        onTimeUpdate?(seconds)
    }

    /// What became of a `load`, which decides what its caller may write.
    ///
    /// A `Bool` said only whether a later *load* had replaced this one. It
    /// could not say that a later *seek* had taken the playhead — a scrub into
    /// the file this load was still opening — so the load went on to run its
    /// own trailing seek over the newer one, and `AudiobookCoordinator` then
    /// restated its clock from the load's offset: the audio and the clock both
    /// ended up where the listener had just left.
    public enum LoadOutcome: Equatable, Sendable {
        /// The item is this call's, and the playhead is where it asked.
        case loaded
        /// The item is this call's, but a seek made while it was opening owns
        /// the playhead. The load ran no trailing seek and left the rate to that
        /// seek. Nothing is wrong with the audio; a caller must simply not
        /// restate a clock from this call's offset.
        case overtaken
        /// A later load replaced the item while this one was awaiting
        /// AVFoundation, and owns everything now.
        case superseded
        /// The file would not open: its duration could not be loaded. The
        /// player has paused, so nothing claims to be playing over silence.
        ///
        /// A missing file, a chunk deleted from disk under a paused book, a
        /// streamed track whose request failed or whose token expired. Every
        /// one of these used to come back as success, with `isPlaying` left
        /// true and every surface drawing a pause glyph over silence while the
        /// sleep timer counted down.
        case failed
    }

    /// Loads an audio file, local or streamed, and says what became of it.
    ///
    /// Readaloud audio lives inside the EPUB, so the caller extracts it first;
    /// this never sees the archive. A streamed audiobook track instead needs
    /// credentials, and `cookies` is how they travel: Storyteller accepts its
    /// session token as an `st_token` cookie, and `AVURLAssetHTTPCookiesKey` is
    /// public API, unlike the header field key everyone reaches for first.
    ///
    /// The guards live here rather than only in `AudiobookCoordinator`, where
    /// one sat *after* the damage: everything past the `await` below writes
    /// player state, so two overlapping loads — a scrub racing an end-of-track
    /// advance, two remote commands in a burst — left `duration` describing one
    /// file while the queue held another, and seeked the new item to the old
    /// one's clip time. Two guards, because two things can overtake a load: a
    /// later load takes the item (`itemGeneration`), and a later seek takes
    /// only the playhead (`playheadGeneration`).
    @discardableResult
    public func load(
        url: URL, href: String, startAt offset: TimeInterval = 0, cookies: [HTTPCookie] = [],
    ) async -> LoadOutcome {
        itemGeneration &+= 1
        playheadGeneration &+= 1
        let item = itemGeneration
        let playhead = playheadGeneration
        // Whatever an earlier start's check would find is about another item.
        stopStartCheck()
        // Until this load or a seek that overtakes it has put the playhead
        // where it belongs, nothing may start the engine — see
        // `placementPending`.
        placementPending = true
        // Each load is a placement of its own: one that replaces a load still
        // placing starts the watchdog's count again, rather than inheriting
        // the first one's and being called stuck for the burst's length.
        placementBeganAt = .now
        placementTarget = offset
        currentAudioHref = href
        // Kept, so a rebuilt engine can open the same thing again.
        source = (url, href, cookies)
        // The clock belongs to the file being replaced. Left alone it kept
        // reporting the previous file's position until the periodic observer
        // next fired — up to a second with the screen off, which is exactly
        // when `previousChapter` reads it to decide between "restart this
        // chapter" and "go back one". A rebuild's load is not a replacement:
        // the file is the same, and the clock is held at the place it reopens.
        let holdsClock = nextLoadHoldsClock
        nextLoadHoldsClock = false
        currentTime = holdsClock ? offset : 0
        // A file on disk whose name is not an audio name — a download is kept as
        // `.epub` — is opened as the type its bytes say; see `AudioFileKind`.
        var options: [String: Any] = url.isFileURL ? AudioFileKind.assetOptions(forFileAt: url) ?? [:] : [:]
        if !cookies.isEmpty { options[AVURLAssetHTTPCookiesKey] = cookies }
        currentItemIsFile = url.isFileURL
        let asset = AVURLAsset(url: url, options: options.isEmpty ? nil : options)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.audioTimePitchAlgorithm = .timeDomain

        observers.removeItemObservers()
        observers.end = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFinishedFile?() }
        }
        // The two ways an item says it has stopped for good rather than reached
        // its end: it never became playable, or it stopped part-way — a stream
        // that lost its network, a file that went from under it. Neither was
        // observed, so the player went on claiming to play.
        observers.failedToEnd = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: playerItem, queue: .main,
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
            let reason = error.map { String(describing: $0) } ?? "unknown"
            let servicesReset = error.map(Self.isMediaServicesReset) ?? false
            MainActor.assumeIsolated {
                self?.itemDidStop(generation: item, reason: reason, servicesReset: servicesReset)
            }
        }
        // Said, not acted on: a stall with nothing behind it ends by itself, and
        // the watchdog is what acts when one does not.
        observers.stalled = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: playerItem, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.logState("audio playback stalled") }
        }
        observers.status = playerItem.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            let reason = observed.error.map { String(describing: $0) } ?? "unknown"
            let servicesReset = observed.error.map(Self.isMediaServicesReset) ?? false
            Task { @MainActor [weak self] in
                self?.itemDidStop(generation: item, reason: reason, servicesReset: servicesReset)
            }
        }

        // Stopped explicitly before the item changes hands, rather than trusting
        // the queue to drop its rate when it empties: the new item must not
        // start until it has been placed — see `placementPending`.
        player.rate = 0
        // A seek still waiting on the outgoing item is released before the
        // item goes. Measured: a seek pending on an item that has failed is
        // never called back, and removing the item does not change that — the
        // coordinator's in-flight counter around it would never come down, and
        // the clock would be ignored for the rest of the session.
        player.currentItem?.cancelPendingSeeks()
        player.removeAllItems()
        player.insert(playerItem, after: nil)
        // Both asked for at once: the tracks are wanted for the gain tap, and
        // asking for them one after the other would be a second network round
        // trip on every streamed track — and a second window in which a later
        // `load` could overtake this one. Both requests are in flight before
        // either is awaited, so this stays one round trip and one window, and
        // the generations are checked once both answers are in.
        //
        // Two of them rather than `load(.duration, .tracks)`, though, because
        // that form is all-or-nothing: a track list that will not load — an
        // HLS playlist, which `makeAudioMix`'s own doc anticipates — nilled the
        // *duration* along with it, so the scrubber lost its length, "…m left"
        // disappeared, and the end-of-track arithmetic ran against zero for an
        // asset whose duration had resolved perfectly well. Caught one at a
        // time, a `.tracks` failure costs the gain tap and nothing else.
        async let loadingDuration = asset.load(.duration)
        async let loadingTracks = asset.load(.tracks)
        if let hook = whileLoadingAsset {
            whileLoadingAsset = nil
            await hook()
        }
        let loadedDuration: CMTime?
        var failure: (any Error)?
        do {
            loadedDuration = try await loadingDuration
        } catch {
            loadedDuration = nil
            failure = error
        }
        let loadedTracks = try? await loadingTracks
        guard item == itemGeneration else { return .superseded }
        // Item-scoped, so written even when a seek has since taken the
        // playhead: the item is still this load's, and these describe it.
        //
        // `?? 0` cannot catch NaN, and a streamed asset with an indefinite
        // duration reports exactly that.
        let seconds = loadedDuration?.seconds ?? 0
        duration = seconds.isFinite ? seconds : 0
        // Before the seek and the rate restore, so the first sample this item
        // plays is already at the book's level. Every read-along file and every
        // audiobook track passes through here, which is why a chapter change
        // needs no separate hook.
        let audioTracks = (loadedTracks ?? []).filter { $0.mediaType == .audio }
        playerItem.audioMix = gainTap.makeAudioMix(for: audioTracks)
        tapCarriesGain = playerItem.audioMix != nil
        applyPlayerVolume()
        // A file that will not open is not a place to be. Stopped here, before
        // anything is told it landed: `isPlaying` is what the transport, the
        // sleep timer and the widget all read.
        if let failure {
            itemDidFail(generation: item, reason: String(describing: failure))
            return .failed
        }
        // Playhead-scoped from here on. A seek made while this load was
        // opening its file — a scrub, the next sentence tapped, a held remote
        // button — has already put the playhead where the listener asked, and
        // restored the rate; seeking back to this load's own offset now is the
        // write that lost it.
        // The item can also fail without its duration throwing: the status
        // observer above stands it down, and nothing past here can place it.
        guard failedItem != item else { return .failed }
        guard playhead == playheadGeneration else { return .overtaken }
        if offset > 0 {
            beforeTrailingSeek?()
            guard await seekPlayhead(offset, generation: playhead) else {
                guard item == itemGeneration else { return .superseded }
                return failedItem == item ? .failed : .overtaken
            }
        } else {
            // Replacing the queue item drops AVPlayer's rate to 0, and a seek is
            // the other path that restores it. An offset of exactly 0 — a scrub
            // back to the start of the book — has no seek, and skipping the
            // restore left the audio silent while `isPlaying` stayed true, so
            // the transport drew a pause glyph over a stopped player.
            placementPending = false
            if isPlaying { player.rate = rate }
        }
        // Asked once more on the way out, because both ways an item says it
        // failed can arrive while it is being placed. The status observer hops
        // through a Task, so with no trailing seek to wait on this method
        // returned before that Task ran; and a failure that lands while the
        // trailing seek is pending releases the seek through
        // `cancelPendingSeeks` without taking the playhead from it, so the seek
        // came back owning the playhead and this said `.loaded` for a dead item
        // — and its caller pressed play over it.
        if playerItem.status == .failed {
            itemDidFail(
                generation: item, reason: playerItem.error.map { String(describing: $0) } ?? "unknown")
        }
        guard failedItem != item else { return .failed }
        return .loaded
    }

    /// Takes the loaded file out of the player, leaving it paused and empty.
    ///
    /// `load` with nothing to load: for a coordinator that is putting its
    /// position back to the start, which has to stop the player describing a
    /// file. The periodic observer is attached to the player rather than to the
    /// item, and it fires on a pause and on a seek as well as on playback — so
    /// while `currentAudioHref` names a file, every tick is a question a
    /// coordinator can answer with a sentence in it. Cleared, `advance(to:)`
    /// has nothing to resolve the clock against.
    ///
    /// Both generations are bumped, so a `load` still opening its file comes
    /// back `.superseded` and a seek still landing returns without writing the
    /// clock or the rate, exactly as if a newer load had replaced them. The
    /// rate the listener chose, and the level, are untouched: they belong to the
    /// player, not to the file.
    ///
    /// The next `load` is a new item and plays, as after any other.
    func unload() {
        pause(reason: .unloaded)
        itemGeneration &+= 1
        playheadGeneration &+= 1
        placementPending = false
        // The end and failure observers go with the item they were watching,
        // and a notification that item had already queued goes with them — see
        // `ReadalongCoordinator.advanceToNextFile`.
        observers.removeItemObservers()
        player.currentItem?.cancelPendingSeeks()
        player.removeAllItems()
        currentAudioHref = nil
        source = nil
        currentTime = 0
        duration = 0
    }

    /// What the newest `load` opened, so `rebuildEngine` can open it again on
    /// a fresh engine. Nil before anything is loaded and after `unload`.
    @ObservationIgnored private var source: (url: URL, href: String, cookies: [HTTPCookie])?
    /// Set by `rebuildEngine` for its own load, which reopens the same file at
    /// the same place: the clock stays there rather than reading zero while
    /// the file opens. Spent by the load that reads it.
    @ObservationIgnored private var nextLoadHoldsClock = false

    /// Bumped by every `load` and by `unload`. Guards what belongs to the
    /// *item*: its duration, its audio mix, the volume fallback that depends on
    /// the mix.
    private var itemGeneration = 0
    /// Bumped by every `load`, every `seek(to:)` and `unload`. Guards what
    /// belongs to the *playhead*: `currentTime`, a load's trailing seek, and the
    /// rate restore that follows a seek. Readable for tests.
    private(set) var playheadGeneration = 0
    /// Whether the newest load's item has yet to be put where it belongs.
    ///
    /// Between `load` inserting a new item and that item's seek landing,
    /// starting the engine plays the new file from its first second — and for
    /// a streamed track that window is a network round trip. `play()` and
    /// `rate` both used to set the engine's rate straight away, as did a
    /// superseded load's seek completing late. They now record the intent and
    /// leave the engine alone; whatever places the item — the load's own tail,
    /// or a seek that overtook it — restores the rate when it lands.
    ///
    /// A flag for the newest item rather than a count of loads in flight: a
    /// load a newer one superseded can stay suspended in AVFoundation for a
    /// network round trip after the newer one has finished, and counting it
    /// held a listener's play button down that whole time.
    private var placementPending = false {
        didSet {
            if !placementPending { placementBeganAt = nil }
            else if !oldValue { placementBeganAt = .now }
        }
    }

    /// Called from inside `load` once its item is in the queue and the asset has
    /// been asked for its duration and tracks, before either answer is awaited.
    ///
    /// `AudiobookCoordinator.whileLoading`'s counterpart one layer down, and a
    /// test seam for the same reason: a seek or a load made inside it lands in
    /// the window a real overtaking command lands in, deterministically. Nil on
    /// every path a listener can reach, spent when it fires, and behind an
    /// `if let`, so a shipping build adds no suspension point.
    var whileLoadingAsset: (@MainActor () async -> Void)?

    /// Called from inside `load` just before its own trailing seek is issued:
    /// the window in which an item that fails leaves that seek to land on a
    /// dead item. A test seam, nil on every path a listener can reach, and
    /// synchronous, so it adds no suspension point.
    var beforeTrailingSeek: (@MainActor () -> Void)?

    /// The rate the engine is set to, for tests: the interesting cases are the
    /// ones where it is not `rate`.
    var engineRate: Float { player.rate }
    /// Where the engine's playhead is, for tests: `currentTime` is what this
    /// class last *said*, and the two disagreeing is the bug class above.
    var engineTime: TimeInterval { player.currentTime().seconds }

    /// Why a start was asked for, which the log says: "the audio stopped"
    /// is answered by what started it and what stopped it, and on 21 Nov
    /// 2026 the log could say neither.
    public enum StartReason: String, Sendable {
        /// The reader, or a command they gave: a button, the lock screen, the
        /// car.
        case reader
        /// An interruption ended and asked for the book to carry on.
        case callEnded
        /// The narration ran on into its next file.
        case nextFile
        /// The engine was rebuilt under a book that was playing.
        case rebuild
        /// The book moved between the car and the reader.
        case handOff
    }

    public func play(because reason: StartReason = .reader) {
        // Nothing is claimed over an item that would not play. The session is
        // non-mixable, so activating it stopped the listener's music — or the
        // car's working stream — and `isPlaying` drew a pause glyph over
        // silence that nothing ever stood down, because `itemDidFail` fires
        // once per item. The coordinators reopen the file instead; see their
        // `resume()`. The next `load` is a new item, and plays.
        guard !itemHasFailed else {
            IssaLog.info("play refused: the loaded audio would not play", [:])
            fail(.wouldNotOpen)
            return
        }
        // Activated here, not in `init`: a non-mixable session interrupts
        // whatever else is playing the moment it goes active, which is right
        // when the listener asks for narration and wrong when they only
        // opened the book.
        // A play is never swallowed: not by an interruption whose end may never
        // come (the system says nothing when it gave the session back before
        // the app was running), and not by one the listener is simply asking
        // to be over. If the system will not hand the session back the play is
        // reported as a failed one is, and nothing claims to be playing.
        guard activateSession() else {
            // Refused while an interruption is under way: the system has the
            // session, so this is the book that interruption's end resumes.
            if isInterrupted {
                wasPlayingBeforeInterruption = true
                latchedAt = interruptionClock()
            }
            IssaLog.info("play refused: the audio session would not activate", [:])
            fail(.audioBusy)
            return
        }
        // The listener's own play is the last word on what an interruption
        // should do afterwards, and ends the one it was asked during.
        wasPlayingBeforeInterruption = false
        latchedAt = nil
        interruptedAt = nil
        // Every start but the rebuild's own gets one rebuild if it turns out
        // to make no sound; the rebuild's start gets none, so a dead audio
        // system ends in a stop and a message rather than a loop.
        if reason != .rebuild { rebuildSpent = false }
        if !isPlaying {
            IssaLog.info("audio playing", [
                "file": currentAudioHref ?? "",
                "at": String(format: "%.1f", currentTime),
                "why": reason.rawValue,
            ])
        }
        isPlaying = true
        // Whatever was said about the last start is over.
        startFailure = nil
        onStartFailure?(nil)
        startWatchdog()
        // Intent only, while a load is still placing its item: see
        // `placementPending`.
        if !placementPending { player.rate = rate }
        // The rate hook fires only from `rate`'s didSet, and this does not touch
        // it — so without this the lock screen kept the old rate for up to five
        // seconds and extrapolated a clock the audio was not following.
        notifyRateObservers(rate)
        // Unless a rate observer has just stopped it again.
        if isPlaying { armStartCheck() }
    }

    /// How many times the player has been paused.
    ///
    /// Read before and after a suspension by a start that means to play when
    /// it gets there: a pause that landed in between is the listener's last
    /// word, and `isPlaying` cannot say so, because a load leaves it as it
    /// was and a start from a paused player must still play.
    public private(set) var pauseCount = 0

    /// What a start takes before it awaits its file: the listener's pauses and
    /// the interruptions so far, so `playAfterStart` can tell what happened in
    /// between.
    public struct StartToken: Sendable {
        fileprivate let pauses: Int
        fileprivate let interruptions: Int
    }

    /// Takes the token a start holds across its await.
    public func beginStart() -> StartToken {
        StartToken(pauses: pauseCount, interruptions: interruptionsBegun)
    }

    /// The tail of a start: plays unless something that happened during its
    /// await says not to. The one place the rule lives, for every start.
    ///
    /// - The listener paused since the token: not played, their last word.
    /// - An interruption began and is still going: not played, and latched, so
    ///   its end resumes the book.
    /// - One began and ended: played if it ended asking for a resume.
    /// - Otherwise played.
    ///
    /// - Returns: whether it played.
    @discardableResult
    public func playAfterStart(_ token: StartToken, because reason: StartReason = .reader) -> Bool {
        guard pauseCount == token.pauses else { return false }
        if interruptionsBegun != token.interruptions {
            if isInterrupted {
                wasPlayingBeforeInterruption = true
                latchedAt = interruptionClock()
                return false
            }
            guard lastInterruptionEndedWithResume else { return false }
        }
        play(because: reason)
        return isPlaying
    }

    /// Stops, and forgets that we were playing before an interruption.
    ///
    /// The latch is set on `.began` and read on `.ended`, and nothing cleared
    /// it in between — so a listener who took a call and then deliberately
    /// paused on the lock screen had the book start again by itself when the
    /// call ended, against an explicit instruction.
    public func pause(reason: StopReason = .requested) {
        pauseCount &+= 1
        stopPlaying(reason: reason)
    }

    /// Why the audio stopped. Logged once per stop, at the one place every
    /// stop goes through, because "the audio suddenly stopped" (17 Nov 2026)
    /// came back as a log with no line at all for the stop: an interruption, a
    /// route loss, the system and the listener all stopped the same way and
    /// said nothing.
    public enum StopReason: String, Sendable {
        /// The reader, the app, or a command the app was given.
        case requested
        /// Another app or a call took the audio session.
        case interruption
        /// The system suspended the app with the session active.
        case systemSuspension
        /// Headphones or a car went away.
        case routeLoss
        /// The item failed to load or stopped part-way.
        case itemFailed
        /// The book ended, or the sleep timer, or anything else that hands the
        /// audio route back.
        case sessionEnded
        /// The narration's place was cleared.
        case unloaded
        /// The watchdog found the audio not moving and could not get it going
        /// again.
        case watchdog
        /// The engine is being replaced; the rebuild plays the book again.
        case rebuild
        /// The engine made no sound after a start, and a fresh one did not
        /// either.
        case engineFailed

        /// What the reader is told about a stop of this kind, which they did
        /// not ask for and would otherwise only hear as silence. Nil for the
        /// stops that explain themselves.
        var failure: StartFailure? {
            switch self {
            case .itemFailed: .wouldNotOpen
            case .watchdog, .engineFailed: .audioStopped
            case .requested, .interruption, .systemSuspension, .routeLoss, .sessionEnded, .unloaded, .rebuild: nil
            }
        }
    }

    /// Stops, without counting as the listener's pause: what `pause()` does,
    /// and what an interruption's pause is.
    private func stopPlaying(reason: StopReason) {
        let wasPlaying = isPlaying
        if isPlaying {
            IssaLog.info("audio stopped", [
                "reason": reason.rawValue,
                "file": currentAudioHref ?? "",
                "at": String(format: "%.1f", currentTime),
            ])
        }
        stopWatchdog()
        stopStartCheck()
        wasPlayingBeforeInterruption = false
        latchedAt = nil
        // A stop is the end of whatever an interruption was holding the book
        // for; `interruptionBegan` sets the state again after its own stop.
        interruptedAt = nil
        isPlaying = false
        player.rate = 0
        notifyRateObservers(0)
        // Said, when it stopped a book that was playing. These stops used to
        // be silent: the button went back to Play and nothing said why. Not
        // during a rebuild, whose own outcome is what the reader is told.
        if wasPlaying, !rebuilding, let failure = reason.failure { fail(failure) }
    }

    // MARK: - A start that made no sound

    /// Why the last start made no sound, until a play goes through.
    public enum StartFailure: String, Sendable {
        /// The file would not open: play was refused over an item that
        /// failed, or the item stopped for good while playing.
        case wouldNotOpen
        /// The system would not hand over the audio: a call, or another app
        /// holding it.
        case audioBusy
        /// The audio stopped responding, and neither the watchdog nor a fresh
        /// engine got it going again.
        case audioStopped
    }

    /// Why the last start failed, for a surface to say under its play button.
    /// Cleared by a play that goes through.
    public private(set) var startFailure: StartFailure?

    /// Told each time a start fails — including the ones found after the
    /// press that asked for it has returned, which no caller is waiting on —
    /// and with nil whenever a play goes through, so a surface still saying
    /// an earlier failure can take it down.
    public var onStartFailure: ((StartFailure?) -> Void)?

    /// What a press that has left nothing playing should say: the failure the
    /// player recorded last, or else that the file would not open, which is
    /// what a start that never reached `play()` is.
    public var failureToReport: StartFailure { startFailure ?? .wouldNotOpen }

    private func fail(_ failure: StartFailure) {
        IssaLog.warning("audio start failed", [
            "why": failure.rawValue, "file": currentAudioHref ?? source?.href ?? "",
        ])
        startFailure = failure
        onStartFailure?(failure)
    }

    /// An item that stopped for good: paused, its seeks released, and logged.
    ///
    /// Only for the item the player still holds — a failure reported for one a
    /// later load replaced is about audio nobody is listening to.
    func itemDidFail(generation: Int, reason: String) {
        // Once per item: the duration load throwing and the status turning
        // `.failed` are usually the same failure, reported twice.
        guard generation == itemGeneration, failedItem != generation else { return }
        failedItem = generation
        placementPending = false
        player.currentItem?.cancelPendingSeeks()
        // Said when it stops a book that was playing (`stopPlaying`); only
        // recorded otherwise, so a surface can still show why nothing plays
        // and a press that reopens this file and fails says the right thing.
        if isPlaying { pause(reason: .itemFailed) } else { startFailure = .wouldNotOpen }
        IssaLog.warning("audio would not play", [
            "href": currentAudioHref ?? "", "error": reason,
        ])
        // The dead file is no longer the one loaded. Left named, every
        // coordinator's "is this file already in the player?" test said yes:
        // a tap on another sentence in the same file took the seek-only branch
        // over a dead item and played, `currentAnchor` named a file that never
        // opened, and the car's "nothing loaded" check passed. Cleared, the
        // next move into this file opens it again.
        currentAudioHref = nil
    }

    /// The item `itemDidFail` last stood down, so it does so once.
    private var failedItem: Int?

    /// Whether the item the player holds is one that would not play: the
    /// newest load failed, or its item stopped for good. `play()` refuses
    /// while it is true, and the next `load` clears it. Observable, so a
    /// surface can say why nothing is playing.
    public var itemHasFailed: Bool { failedItem != nil && failedItem == itemGeneration }
    /// The current item's generation, for tests that report a failure on it.
    var itemGenerationForTests: Int { itemGeneration }

    // MARK: - When "playing" is not playing

    /// What a stall looked like when the watchdog found it.
    public enum StallKind: String, Sendable {
        /// Meant to be playing, the clock has not moved.
        case frozen
        /// A load or a seek has not finished placing the playhead.
        case stuckPlacement
        /// Stopped at the end of the file with no end notification: the
        /// coordinator's file change never ran.
        case missedEnd
    }

    /// How often the watchdog looks. Variables so tests can run in a second.
    var watchdogInterval: Duration = .seconds(2)
    /// How long the clock may stand still while meant to be playing.
    var stallThreshold: Duration = .seconds(8)
    /// How long a load or a seek may take to place the playhead.
    var placementThreshold: Duration = .seconds(10)
    /// A second stall this soon after a recovery is not recovered from again:
    /// the audio is stopped, said so, and the place saved.
    var recoveryWindow: Duration = .seconds(30)
    /// The engine's clock, for a test to hold still.
    var engineClock: (() -> TimeInterval)?

    /// How many stalls the watchdog has tried to recover from.
    public private(set) var stallRecoveries = 0

    private var watchdog: Task<Void, Never>?
    private var progress: (time: TimeInterval, at: ContinuousClock.Instant)?
    private var placementBeganAt: ContinuousClock.Instant?
    private var seekBeganAt: ContinuousClock.Instant?
    /// Where the load or seek still placing the playhead was taking it. A
    /// stuck placement is placed again *there*: `currentTime` is the wrong
    /// answer, because `load` zeroes it before it awaits — re-placing at it
    /// sent a book opened an hour into a file back to that file's first
    /// second — and during a hung seek it is the place the listener just
    /// skipped away from.
    private var placementTarget: TimeInterval?
    private var lastRecoveryAt: ContinuousClock.Instant?
    /// Whether the current item is a file on this device. A streamed one
    /// (an audiobook track over HTTP) buffers as a matter of course, and the
    /// player does not wait to minimise stalls, so a frozen clock there is
    /// logged and left alone rather than re-placed over and over.
    var currentItemIsFile = false

    /// Why this exists: on 17 Nov 2026 a read-along stopped mid-file and the
    /// app went on believing it was playing for two hours — a later tap on
    /// the play button logged "narration paused" over a place that had not
    /// moved, and nothing in between said a word. Every stop the player makes
    /// itself sets `isPlaying` false, so the audio stopped underneath it.
    ///
    /// Its own timer, because the periodic time observer does not fire while
    /// the timebase is frozen — the very state it has to notice.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        progress = nil
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.watchdogInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.checkForStall()
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
        progress = nil
    }

    /// One look. Not while paused, interrupted or empty — none of those is
    /// meant to be moving.
    func checkForStall(now: ContinuousClock.Instant = .now) {
        guard isPlaying, !isInterrupted, player.currentItem != nil else {
            progress = nil
            return
        }
        if let began = placementBeganAt ?? seekBeganAt {
            // Placing is not playing, and a long `startAt` seek into a big
            // file takes a moment; only one that never finishes is a stall.
            progress = nil
            if now - began >= placementThreshold {
                stalled(.stuckPlacement, at: placementTarget ?? currentTime)
            }
            return
        }
        let time = engineClock?() ?? player.currentTime().seconds
        guard time.isFinite else { return }
        guard let last = progress, abs(time - last.time) < 0.2 else {
            progress = (time, now)
            return
        }
        guard now - last.at >= stallThreshold else { return }
        let atEnd = duration > 0 && time >= duration - 0.75
        stalled(atEnd ? .missedEnd : .frozen, at: time)
    }

    private func stalled(_ kind: StallKind, at time: TimeInterval) {
        progress = nil
        logState("audio not moving", ["kind": kind.rawValue])
        guard currentItemIsFile else { return }
        let now = ContinuousClock.now
        if let last = lastRecoveryAt, now - last < recoveryWindow {
            IssaLog.warning("audio could not be restarted", [
                "kind": kind.rawValue, "file": currentAudioHref ?? "",
            ])
            pause(reason: .watchdog)
            return
        }
        lastRecoveryAt = now
        stallRecoveries += 1
        switch kind {
        case .missedEnd:
            // The end the item never announced: what the end observer would
            // have done.
            onFinishedFile?()
        case .frozen, .stuckPlacement:
            // A seek that never calls back is completed (as not finished) by
            // cancelling it, which lets whatever awaited it go on; then the
            // playhead is placed again where the clock stopped, and placing
            // restores the rate.
            player.currentItem?.cancelPendingSeeks()
            Task { [weak self] in await self?.seek(to: time) }
        }
    }

    /// The audio system restarted under the app, and every engine it had is
    /// dead: the old player takes a rate and makes no sound. Re-placing it,
    /// which this used to do, re-seeked that same dead player — and for a
    /// streamed track did nothing at all — so the book claimed to play over
    /// silence. Internal so a test can deliver the notice the system would.
    func mediaServicesWereReset() {
        logState("audio services were reset")
        Self.configureAudioSession()
        startRebuild(because: .servicesReset)
    }

    // MARK: - Rebuilding the engine

    /// What made the engine be rebuilt, for the log.
    enum RebuildCause: String, Sendable {
        /// The system said its media services were reset.
        case servicesReset
        /// The item reported the reset (-11819) before the notice did.
        case itemReset
        /// The player itself went `.failed`.
        case engineFailed
        /// A start was found making no sound.
        case deadStart
    }

    /// Whether a rebuild is under way. Ticks are swallowed and a second
    /// request is ignored while it is.
    private(set) var rebuilding = false
    /// Whether the start now running has had its one rebuild. Cleared by
    /// every start but the rebuild's own; see `play(because:)`.
    private var rebuildSpent = false
    /// How many rebuilds have begun, for tests and the log.
    private(set) var rebuilds = 0
    /// The rebuild under way, for a test to await.
    private(set) var rebuildTask: Task<Void, Never>?

    /// Which engine is in use, for tests: a rebuild changes it.
    var engineIdentity: ObjectIdentifier { ObjectIdentifier(player) }

    /// The error AVFoundation reports, on every item and engine it had, when
    /// the media services were reset: `AVError.mediaServicesWereReset`, by
    /// number, because the Mac's SDK does not name it.
    nonisolated static func isMediaServicesReset(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == AVFoundationErrorDomain && error.code == -11819
    }

    /// An item's report that it stopped for good. One cause is not the
    /// item's: -11819 says the media services were reset, and the engine went
    /// with them. That is rebuilt, and handled before `itemDidFail`, whose
    /// pause would lose that the book was playing. Not while a load is placing
    /// its item (that load's caller is told it failed) or during a rebuild
    /// (whose own load failing is its answer).
    func itemDidStop(generation: Int, reason: String, servicesReset: Bool) {
        if servicesReset, generation == itemGeneration, !rebuilding, !placementPending {
            logState("audio item reset with the media services", ["error": reason])
            engineDied(because: .itemReset)
            return
        }
        itemDidFail(generation: generation, reason: reason)
    }

    /// The player's own status, which goes `.failed` when the engine is gone
    /// for good. Nothing watched it, so a failed engine read as a playing one.
    private func observeEngineStatus() {
        let engine = engineGeneration
        observers.engineStatus = player.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            let reason = observed.error.map { String(describing: $0) } ?? "unknown"
            Task { @MainActor [weak self] in self?.engineFailed(engine: engine, reason: reason) }
        }
    }

    /// The engine `engine` went `.failed`. Internal for the tests.
    func engineFailed(engine: Int, reason: String) {
        guard engine == engineGeneration else { return }
        logState("audio engine failed", ["error": reason])
        engineDied(because: .engineFailed)
    }

    /// The engine is not making sound and cannot: rebuilt once per start, and
    /// after that the book is stopped and the reader told.
    private func engineDied(because cause: RebuildCause) {
        guard rebuildSpent else {
            startRebuild(because: cause)
            return
        }
        // A paused book has nothing to stop or report; the next press gets a
        // rebuild of its own.
        guard isPlaying, !rebuilding else {
            IssaLog.info("audio engine dead after its rebuild", ["cause": cause.rawValue])
            return
        }
        giveUp(cause)
    }

    /// Throws the engine away and opens the book again on a new one, where it
    /// was, playing if it was — unless a rebuild is already running: a second
    /// reset notice for the same reset, or the item's -11819 arriving beside
    /// the notice, must not throw away the engine the first is putting back.
    ///
    /// The old engine goes here, in the same turn as the request, so nothing
    /// it or its item reports afterwards can land on the book between the
    /// request and the reopening. Everything the reader set comes back
    /// through `load`, which restores the place, the gain tap and the volume
    /// on whatever engine it finds, and the rate when the book plays. The play
    /// goes through `playAfterStart`, so a pause, a lost route or an
    /// interruption that lands while the file reopens is the last word; a
    /// paused book keeps any interruption's latch, so the end of a call still
    /// resumes it on the new engine.
    private func startRebuild(because cause: RebuildCause) {
        guard !rebuilding else {
            IssaLog.info("audio engine rebuild already running", ["cause": cause.rawValue])
            return
        }
        rebuilding = true
        rebuildSpent = true
        rebuilds += 1
        let wasPlaying = isPlaying
        // Where the book is: the place a load or seek is still taking it to,
        // or the clock. Not the dead engine's own time, which may be anything.
        let place = placing ? (placementTarget ?? currentTime) : currentTime
        let token = beginStart()
        let reopening = source
        IssaLog.warning("audio engine rebuilding", [
            "cause": cause.rawValue, "file": reopening?.href ?? "",
            "at": String(format: "%.1f", place), "intent": wasPlaying ? "playing" : "paused",
        ])
        // The system's stop, not the listener's, so it is not counted as a
        // pause. Only for a book that was playing: one that was not may hold
        // an interruption's latch, which a stop would clear, and a playing one
        // cannot — `play()` clears it.
        if wasPlaying { stopPlaying(reason: .rebuild) }
        makeEngine()
        // The old item, its seeks and any load still opening it are gone with
        // the engine: anything they report from here on is out of date, and
        // a load that was opening comes back superseded, as `unload` leaves it.
        itemGeneration &+= 1
        playheadGeneration &+= 1
        placementPending = false
        Self.configureAudioSession()
        if wasPlaying { _ = activateSession() }
        rebuildTask = Task { [weak self] in
            await self?.reopen(reopening, at: place, wasPlaying: wasPlaying, token: token, cause: cause)
        }
    }

    /// The rest of a rebuild: the book opened again on the new engine.
    private func reopen(
        _ reopening: (url: URL, href: String, cookies: [HTTPCookie])?, at place: TimeInterval,
        wasPlaying: Bool, token: StartToken, cause: RebuildCause,
    ) async {
        guard let reopening else {
            rebuilding = false
            IssaLog.info("audio engine rebuilt", ["cause": cause.rawValue, "outcome": "empty"])
            return
        }
        nextLoadHoldsClock = true
        let outcome = await load(
            url: reopening.url, href: reopening.href, startAt: place, cookies: reopening.cookies)
        rebuilding = false
        IssaLog.info("audio engine rebuilt", [
            "cause": cause.rawValue, "outcome": String(describing: outcome), "file": reopening.href,
        ])
        switch outcome {
        case .loaded, .overtaken, .superseded:
            // Superseded too: a newer load — the next file, a sentence
            // tapped — owns the item, but the book was playing, and the token
            // still refuses if anyone paused or took the session meanwhile.
            if wasPlaying { playAfterStart(token, because: .rebuild) }
        case .failed:
            if wasPlaying || isPlaying { giveUp(cause) }
        }
    }

    /// The book stopped, with the reason, and the reader told: a fresh engine
    /// did not bring the sound back, so pressing Play is the honest next step.
    private func giveUp(_ cause: RebuildCause) {
        IssaLog.warning("audio engine given up", [
            "cause": cause.rawValue, "file": currentAudioHref ?? source?.href ?? "",
        ])
        if isPlaying { pause(reason: .engineFailed) } else { fail(.audioStopped) }
    }

    // MARK: - The start check

    /// How long after a start the engine is asked whether it is really
    /// playing. A variable, as the watchdog's intervals are, so a test can
    /// drive the check by hand through `checkStart(now:)`.
    var startCheckDelay: Duration = .seconds(1)
    /// The engine's transport state, for a test to stand in for.
    var engineTimeControl: (() -> AVPlayer.TimeControlStatus)?
    /// Marks the engine now in use as failed, for tests: what `player.status`
    /// says when the engine is gone. A rebuilt engine is not marked.
    func markEngineFailedForTests() { engineMarkedFailed = engineGeneration }
    private var engineMarkedFailed: Int?

    /// What a start's check measures from: the engine's time when it began,
    /// the playhead it began under, and when.
    private struct StartCheck {
        let time: TimeInterval
        let playhead: Int
        let at: ContinuousClock.Instant
    }
    @ObservationIgnored private var startCheck: StartCheck?
    @ObservationIgnored private var startCheckTask: Task<Void, Never>?

    private var engineNow: TimeInterval { engineClock?() ?? player.currentTime().seconds }
    private var placing: Bool { placementPending || seekBeganAt != nil }

    /// Arms the one look a start gets, about a second after it. Why: on 21
    /// Nov 2026 a press after a phone call drew Pause over silence, and the
    /// watchdog — which waits sixteen seconds and leaves streams alone — never
    /// said a word. A start that makes no sound is found here instead.
    ///
    /// Not while a load or a seek is still placing the playhead: the engine is
    /// held until it lands, and a placement that never lands is the
    /// watchdog's (`StallKind.stuckPlacement`).
    private func armStartCheck() {
        guard !placing else {
            stopStartCheck()
            return
        }
        startCheck = StartCheck(time: engineNow, playhead: playheadGeneration, at: .now)
        startCheckTask?.cancel()
        startCheckTask = Task { @MainActor [weak self] in
            guard let delay = self?.startCheckDelay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.checkStart()
        }
    }

    /// Disarms it: a pause, a stop, a new load or an unload makes whatever
    /// the earlier start would have found out of date.
    private func stopStartCheck() {
        startCheckTask?.cancel()
        startCheckTask = nil
        startCheck = nil
    }

    /// The look, once. Dead means the engine failed; or it is meant to play
    /// and the engine is paused; or a file on this device has not moved a
    /// tenth of a second. Everything something else owns is left to it: a
    /// pause, an interruption (its end resumes), a placement in flight and a
    /// seek since the start (the watchdog), an item that failed
    /// (`itemDidFail`), a rebuild already running, and an item that has
    /// played to its end while the coordinator opens the next file — it
    /// keeps `isPlaying` across that boundary, and a check there would
    /// rebuild at every file end.
    func checkStart(now: ContinuousClock.Instant = .now) {
        guard let check = startCheck, now - check.at >= .milliseconds(500) else { return }
        stopStartCheck()
        guard isPlaying, !isInterrupted, !rebuilding, !placing, !itemHasFailed,
              check.playhead == playheadGeneration, let item = player.currentItem,
              item.status != .failed
        else { return }
        guard let fault = startFault(since: check.time) else { return }
        logState("audio start made no sound", ["fault": fault])
        engineDied(because: .deadStart)
    }

    /// What is wrong with a start meant to be making sound, or nil.
    private func startFault(since baseline: TimeInterval) -> String? {
        if player.status == .failed || engineMarkedFailed == engineGeneration { return "engineFailed" }
        let time = engineNow
        // At the end of a file the item pauses itself until the coordinator
        // loads the next; that is not a dead start.
        if duration > 0, time.isFinite, time >= duration - 0.75 { return nil }
        switch engineTimeControl?() ?? player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
            // Buffering — what a stream that has run dry reports — and never
            // dead: the watchdog's to judge.
            return nil
        case .paused:
            return "paused"
        case .playing:
            break
        @unknown default:
            return nil
        }
        // By the clock only for a file on this device. A stream is judged by
        // its status alone: one that is playing but has not moved is still
        // filling its buffer.
        if currentItemIsFile, time.isFinite, abs(time - baseline) < 0.1 { return "clockStill" }
        return nil
    }

    /// The engine's own account of itself, logged when it disagrees with the
    /// intent: waiting while meant to be playing (with why), or paused by
    /// something other than this class.
    private func observeTimeControl() {
        observers.timeControl = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.timeControlChanged() }
        }
    }

    private func timeControlChanged() {
        guard isPlaying, !placementPending, seekBeganAt == nil else { return }
        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
            logState("audio waiting")
        case .paused:
            // At the end of a file the item pauses itself (`actionAtItemEnd`)
            // until the next one is loaded; that is not news.
            let time = player.currentTime().seconds
            guard !(duration > 0 && time.isFinite && time >= duration - 0.75) else { return }
            logState("audio paused by the system")
        case .playing:
            break
        @unknown default:
            break
        }
    }

    /// One line with everything that says why audio is or is not moving.
    private func logState(_ message: String, _ extra: [String: String] = [:]) {
        let item = player.currentItem
        var fields: [String: String] = [
            "file": currentAudioHref ?? "",
            "at": String(format: "%.1f", player.currentTime().seconds),
            "intent": isPlaying ? "playing" : "paused",
            "status": Self.describe(player.timeControlStatus),
            "waiting": player.reasonForWaitingToPlay?.rawValue ?? "",
            "item": item.map { Self.describe($0.status) } ?? "none",
            "bufferEmpty": item.map { String($0.isPlaybackBufferEmpty) } ?? "",
            "rate": String(player.rate),
            "placing": String(placementPending || seekBeganAt != nil),
        ]
        fields.merge(extra) { _, new in new }
        IssaLog.info(message, fields)
    }

    private static func describe(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        case .playing: "playing"
        @unknown default: "unknown"
        }
    }

    private static func describe(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: "unknown"
        case .readyToPlay: "ready"
        case .failed: "failed"
        @unknown default: "other"
        }
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Moves the playhead, and owns it until something newer does.
    ///
    /// A load still opening this file loses its trailing seek to this one —
    /// see `LoadOutcome.overtaken`.
    ///
    /// - Returns: whether the playhead landed there and this seek still owns
    ///   it. False when the item would not play — `itemHasFailed` then says
    ///   so — or when something newer took the playhead. It used to answer
    ///   nothing, so a seek on a dead item read as a move that had happened.
    @discardableResult
    public func seek(to seconds: TimeInterval) async -> Bool {
        playheadGeneration &+= 1
        return await seekPlayhead(seconds, generation: playheadGeneration)
    }

    /// The tail every seek shares, a load's own trailing seek included.
    ///
    /// The clock and the rate are written only if nothing has taken the
    /// playhead since `generation` was issued. They were written regardless:
    /// a load's seek interrupted by the next load completes — AVFoundation
    /// calls an interrupted seek back with `finished == false` — and went on to
    /// set the clock to the old file's offset and start the *new* item from
    /// its first second, before that load's own seek had landed.
    ///
    /// - Returns: whether this seek still owned the playhead when it landed.
    @discardableResult
    func seekPlayhead(_ seconds: TimeInterval, generation: Int) async -> Bool {
        // Not asked of an item that has failed: AVFoundation never calls such
        // a seek back — measured — and whoever awaits it would wait for good.
        // There is nowhere in that item to go.
        if let current = player.currentItem, current.status == .failed {
            itemDidFail(
                generation: itemGeneration,
                reason: current.error.map { String(describing: $0) } ?? "unknown")
            return false
        }
        let target = Self.cmTime(forSeconds: seconds)
        // Exact seeking: a read-along highlight lands on the wrong sentence if
        // the player rounds to the nearest keyframe.
        seekBeganAt = .now
        placementTarget = seconds
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        seekBeganAt = nil
        guard generation == playheadGeneration else { return false }
        // The time asked for, unless it is not a time at all; then where the
        // engine was actually sent, so the clock never holds an infinity.
        currentTime = seconds.isFinite ? seconds : target.seconds
        // Placed: the engine may run, and this is what restores it.
        placementPending = false
        if isPlaying { player.rate = rate }
        return true
    }

    /// The engine's target for a time in seconds: the 1/600 s timescale,
    /// rounded up, and saturating rather than trapping.
    ///
    /// Rounded *up* rather than to nearest. A sentence rarely begins on an
    /// exact 1/600 of a second, so half of all targets used to quantise a
    /// fraction of a millisecond *below* the sentence they name — and the
    /// fragment lookup is half-open, so the next tick resolved to the sentence
    /// before, dragged the highlight back, and across a document turned the
    /// page back and told the sleep timer a chapter had ended. Up to 1/600 s
    /// late is inaudible; early is visible.
    ///
    /// Saturating, because a seek target is whatever a book says. `SMILClock`
    /// refuses only the non-finite and the negative, so a `clipBegin` of
    /// `1e20s` reaches here, and so does a manifest track claiming `1e300`
    /// seconds; `CMTimeValue(Double)` traps past `Int64.max / 600` seconds —
    /// about 1.5e16 — and on infinity, which crashed the app every time such a
    /// book was opened at that place. Anything past the largest value the
    /// timescale can hold is a seek to the end of the item, which is where
    /// AVFoundation puts a seek past it anyway. NaN is no place, and goes to
    /// the start, as `max(0, .nan)` always sent it.
    static func cmTime(forSeconds seconds: TimeInterval) -> CMTime {
        guard !seconds.isNaN else { return .zero }
        let ticks = (max(0, seconds) * 600).rounded(.up)
        guard let value = CMTimeValue(exactly: ticks) else {
            return CMTime(value: .max, timescale: 600)
        }
        return CMTime(value: value, timescale: 600)
    }

    public func skip(by delta: TimeInterval) async {
        await seek(to: max(0, currentTime + delta))
    }
}


/// Holds AVFoundation and NotificationCenter tokens outside the main actor.
///
/// A `@MainActor` type's `deinit` is nonisolated, so it cannot read isolated
/// stored properties. Keeping the tokens here lets teardown happen wherever the
/// object is released without weakening the isolation of everything else.
private final class ObserverTokens: @unchecked Sendable {
    /// The engine in use, which the time observer belongs to. Held here as
    /// well as on the actor because `deinit` cannot read the actor's own
    /// variable, and a time observer can only be removed from its player.
    var player: AVQueuePlayer?
    var time: Any?
    var end: (any NSObjectProtocol)?
    var failedToEnd: (any NSObjectProtocol)?
    var status: NSKeyValueObservation?
    var stalled: (any NSObjectProtocol)?
    var interruption: (any NSObjectProtocol)?
    var route: (any NSObjectProtocol)?
    var mediaReset: (any NSObjectProtocol)?
    var timeControl: NSKeyValueObservation?
    var engineStatus: NSKeyValueObservation?

    func removeTimeObserver(from player: AVPlayer) {
        if let time { player.removeTimeObserver(time) }
        time = nil
    }

    /// Everything observed on the engine itself.
    func removeEngineObservers() {
        timeControl?.invalidate()
        timeControl = nil
        engineStatus?.invalidate()
        engineStatus = nil
    }

    /// Everything observed on the current item.
    func removeItemObservers() {
        if let end { NotificationCenter.default.removeObserver(end) }
        end = nil
        if let failedToEnd { NotificationCenter.default.removeObserver(failedToEnd) }
        failedToEnd = nil
        status?.invalidate()
        status = nil
        if let stalled { NotificationCenter.default.removeObserver(stalled) }
        stalled = nil
    }

    func tearDown() {
        if let player { removeTimeObserver(from: player) }
        removeItemObservers()
        for token in [interruption, route, mediaReset].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(token)
        }
        interruption = nil
        route = nil
        mediaReset = nil
        removeEngineObservers()
        player = nil
    }
}
