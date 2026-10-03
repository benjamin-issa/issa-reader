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
    public private(set) var isPlaying = false
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

    private let player = AVQueuePlayer()
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
        player.actionAtItemEnd = .pause
        // Spoken audio at 1.5–3x is unlistenable without pitch correction, and
        // the time-domain algorithm is the one tuned for speech rather than
        // music.
        player.automaticallyWaitsToMinimizeStalling = false
        observeTime(interval: Self.idleObservationInterval)
    }

    deinit {
        observers.tearDown(player: player)
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
    static func activateAudioSession() {
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
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
        pause()
        sessionsEnded += 1
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

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
            MainActor.assumeIsolated {
                guard let self, let rawType,
                      let type = AVAudioSession.InterruptionType(rawValue: rawType)
                else { return }
                switch type {
                case .began:
                    // Latched *after* the pause, not before: `pause()` clears
                    // it, because an explicit pause during an interruption must
                    // not be undone when the interruption ends. Setting it
                    // first would have this pause wipe the very flag it is
                    // recording.
                    let wasPlaying = self.isPlaying
                    self.pause()
                    self.wasPlayingBeforeInterruption = wasPlaying
                    self.onInterruption?(false)
                case .ended:
                    let options = rawOptions.map(AVAudioSession.InterruptionOptions.init) ?? []
                    let shouldResume = options.contains(.shouldResume)
                        && self.wasPlayingBeforeInterruption
                    // Spent, either way. Without clearing it a second `.ended`
                    // with no intervening `.began` — which the system does
                    // deliver — resumed a book the listener had stopped.
                    self.wasPlayingBeforeInterruption = false
                    if shouldResume {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.play()
                    }
                    self.onInterruption?(shouldResume)
                @unknown default:
                    break
                }
            }
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
                self.pause()
                self.onRouteLoss?()
            }
        }
        #endif
    }

    /// Whether the interruption arrived mid-playback, so a resume is only
    /// offered to someone who was actually listening.
    private var wasPlayingBeforeInterruption = false

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
        observeTime(interval: enabled ? Self.activeObservationInterval : Self.idleObservationInterval)
    }

    private func observeTime(interval: TimeInterval) {
        observers.removeTimeObserver(from: player)
        let time = CMTime(seconds: interval, preferredTimescale: 600)
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
                self.currentTime = seconds
                self.onTimeUpdate?(seconds)
            }
        }
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
        // Until this load or a seek that overtakes it has put the playhead
        // where it belongs, nothing may start the engine — see
        // `placementPending`.
        placementPending = true
        currentAudioHref = href
        // The clock belongs to the file being replaced. Left alone it kept
        // reporting the previous file's position until the periodic observer
        // next fired — up to a second with the screen off, which is exactly
        // when `previousChapter` reads it to decide between "restart this
        // chapter" and "go back one".
        currentTime = 0
        let asset = AVURLAsset(
            url: url,
            options: cookies.isEmpty ? nil : [AVURLAssetHTTPCookiesKey: cookies],
        )
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
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error)
                .map { String(describing: $0) } ?? "unknown"
            MainActor.assumeIsolated { self?.itemDidFail(generation: item, reason: reason) }
        }
        observers.status = playerItem.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            let reason = observed.error.map { String(describing: $0) } ?? "unknown"
            Task { @MainActor [weak self] in self?.itemDidFail(generation: item, reason: reason) }
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

    /// Bumped by every `load`. Guards what belongs to the *item*: its
    /// duration, its audio mix, the volume fallback that depends on the mix.
    private var itemGeneration = 0
    /// Bumped by every `load` and every `seek(to:)`. Guards what belongs to the
    /// *playhead*: `currentTime`, a load's trailing seek, and the rate restore
    /// that follows a seek. Readable for tests.
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
    private var placementPending = false

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

    public func play() {
        // Nothing is claimed over an item that would not play. The session is
        // non-mixable, so activating it stopped the listener's music — or the
        // car's working stream — and `isPlaying` drew a pause glyph over
        // silence that nothing ever stood down, because `itemDidFail` fires
        // once per item. The coordinators reopen the file instead; see their
        // `resume()`. The next `load` is a new item, and plays.
        guard !itemHasFailed else {
            IssaLog.info("play refused: the loaded audio would not play", [:])
            return
        }
        // Activated here, not in `init`: a non-mixable session interrupts
        // whatever else is playing the moment it goes active, which is right
        // when the listener asks for narration and wrong when they only
        // opened the book.
        Self.activateAudioSession()
        isPlaying = true
        // Intent only, while a load is still placing its item: see
        // `placementPending`.
        if !placementPending { player.rate = rate }
        // The rate hook fires only from `rate`'s didSet, and this does not touch
        // it — so without this the lock screen kept the old rate for up to five
        // seconds and extrapolated a clock the audio was not following.
        notifyRateObservers(rate)
    }

    /// Stops, and forgets that we were playing before an interruption.
    ///
    /// The latch is set on `.began` and read on `.ended`, and nothing cleared
    /// it in between — so a listener who took a call and then deliberately
    /// paused on the lock screen had the book start again by itself when the
    /// call ended, against an explicit instruction.
    public func pause() {
        wasPlayingBeforeInterruption = false
        isPlaying = false
        player.rate = 0
        notifyRateObservers(0)
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
        if isPlaying { pause() }
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
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
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
    var time: Any?
    var end: (any NSObjectProtocol)?
    var failedToEnd: (any NSObjectProtocol)?
    var status: NSKeyValueObservation?
    var interruption: (any NSObjectProtocol)?
    var route: (any NSObjectProtocol)?

    func removeTimeObserver(from player: AVPlayer) {
        if let time { player.removeTimeObserver(time) }
        time = nil
    }

    /// Everything observed on the current item.
    func removeItemObservers() {
        if let end { NotificationCenter.default.removeObserver(end) }
        end = nil
        if let failedToEnd { NotificationCenter.default.removeObserver(failedToEnd) }
        failedToEnd = nil
        status?.invalidate()
        status = nil
    }

    func tearDown(player: AVPlayer) {
        removeTimeObserver(from: player)
        removeItemObservers()
        for token in [interruption, route].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(token)
        }
        interruption = nil
        route = nil
    }
}
