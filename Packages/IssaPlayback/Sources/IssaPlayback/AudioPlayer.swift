import AVFoundation
import Foundation
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
    public var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }

    public var rate: Float = 1.0 {
        didSet {
            player.rate = isPlaying ? rate : 0
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

    public func removeRateObserver(for owner: AnyObject) {
        rateObservers[ObjectIdentifier(owner)] = nil
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
                    self.wasPlayingBeforeInterruption = self.isPlaying
                    self.pause()
                    self.onInterruption?(false)
                case .ended:
                    let options = rawOptions.map(AVAudioSession.InterruptionOptions.init) ?? []
                    let shouldResume = options.contains(.shouldResume)
                        && self.wasPlayingBeforeInterruption
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

    /// Loads an audio file, local or streamed.
    ///
    /// Readaloud audio lives inside the EPUB, so the caller extracts it first;
    /// this never sees the archive. A streamed audiobook track instead needs
    /// credentials, and `cookies` is how they travel: Storyteller accepts its
    /// session token as an `st_token` cookie, and `AVURLAssetHTTPCookiesKey` is
    /// public API, unlike the header field key everyone reaches for first.
    public func load(
        url: URL, href: String, startAt offset: TimeInterval = 0, cookies: [HTTPCookie] = [],
    ) async {
        currentAudioHref = href
        let asset = AVURLAsset(
            url: url,
            options: cookies.isEmpty ? nil : [AVURLAssetHTTPCookiesKey: cookies],
        )
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain

        observers.removeEndObserver()
        observers.end = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFinishedFile?() }
        }

        player.removeAllItems()
        player.insert(item, after: nil)
        // `?? 0` cannot catch NaN, and a streamed asset with an indefinite
        // duration reports exactly that.
        let loaded = (try? await asset.load(.duration).seconds) ?? 0
        duration = loaded.isFinite ? loaded : 0
        if offset > 0 {
            await seek(to: offset)
        } else if isPlaying {
            // Replacing the queue item drops AVPlayer's rate to 0, and the
            // seek above is the only path in this method that restores it. An
            // offset of exactly 0 — a scrub back to the start of the book —
            // skipped it, leaving the audio silent while `isPlaying` stayed
            // true, so the transport drew a pause glyph over a stopped player.
            player.rate = rate
        }
    }

    public func play() {
        // Activated here, not in `init`: a non-mixable session interrupts
        // whatever else is playing the moment it goes active, which is right
        // when the listener asks for narration and wrong when they only
        // opened the book.
        Self.activateAudioSession()
        isPlaying = true
        player.rate = rate
        // The rate hook fires only from `rate`'s didSet, and this does not touch
        // it — so without this the lock screen kept the old rate for up to five
        // seconds and extrapolated a clock the audio was not following.
        notifyRateObservers(rate)
    }

    public func pause() {
        isPlaying = false
        player.rate = 0
        notifyRateObservers(0)
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func seek(to seconds: TimeInterval) async {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // Exact seeking: a read-along highlight lands on the wrong sentence if
        // the player rounds to the nearest keyframe.
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
        if isPlaying { player.rate = rate }
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
    var interruption: (any NSObjectProtocol)?
    var route: (any NSObjectProtocol)?

    func removeTimeObserver(from player: AVPlayer) {
        if let time { player.removeTimeObserver(time) }
        time = nil
    }

    func removeEndObserver() {
        if let end { NotificationCenter.default.removeObserver(end) }
        end = nil
    }

    func tearDown(player: AVPlayer) {
        removeTimeObserver(from: player)
        removeEndObserver()
        for token in [interruption, route].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(token)
        }
        interruption = nil
        route = nil
    }
}
