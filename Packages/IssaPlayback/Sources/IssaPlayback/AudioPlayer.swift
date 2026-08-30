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

    public var rate: Float = 1.0 {
        didSet {
            player.rate = isPlaying ? rate : 0
            onRateChange?(rate)
        }
    }

    /// Called on every observed time update, so a coordinator can advance the
    /// read-along highlight without polling.
    public var onTimeUpdate: ((TimeInterval) -> Void)?
    public var onRateChange: ((Float) -> Void)?
    public var onFinishedFile: (() -> Void)?

    private let player = AVQueuePlayer()
    /// Observer tokens live outside the actor so `deinit` — which is
    /// nonisolated under Swift 6 — can still tear them down.
    private let observers = ObserverTokens()

    public init() {
        Self.configureAudioSession()
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

    /// Prepares the session for spoken audio.
    ///
    /// `.playback` keeps sound going when the ring switch is silent and when the
    /// screen locks, which is the whole point of an audiobook app; `.spokenAudio`
    /// tells the system this is speech, so it ducks and resumes the way podcasts
    /// do rather than behaving like music. Without an active session, playback
    /// is silent on a device even though the player reports it is running.
    static func configureAudioSession() {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
        #endif
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
        observeTime(interval: enabled ? Self.activeObservationInterval : Self.idleObservationInterval)
    }

    private func observeTime(interval: TimeInterval) {
        observers.removeTimeObserver(from: player)
        let time = CMTime(seconds: interval, preferredTimescale: 600)
        observers.time = player.addPeriodicTimeObserver(forInterval: time, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.currentTime = time.seconds
                self.onTimeUpdate?(time.seconds)
            }
        }
    }

    /// Loads a local audio file. Readaloud audio lives inside the EPUB, so the
    /// caller extracts it first; this never sees the archive.
    public func load(url: URL, href: String, startAt offset: TimeInterval = 0) async {
        currentAudioHref = href
        let asset = AVURLAsset(url: url)
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
        duration = (try? await asset.load(.duration).seconds) ?? 0
        if offset > 0 { await seek(to: offset) }
    }

    public func play() {
        isPlaying = true
        player.rate = rate
    }

    public func pause() {
        isPlaying = false
        player.rate = 0
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
    }
}
