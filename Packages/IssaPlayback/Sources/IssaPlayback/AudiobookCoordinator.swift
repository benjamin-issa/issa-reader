import AVFoundation
import Foundation
import IssaCore
import Observation

/// Plays a plain audiobook: many files, presented as one continuous book.
///
/// A readaloud has a SMIL timeline to drive it; an audiobook has only a list of
/// tracks, so this builds the same virtual book clock from track durations —
/// one scrubber across the whole book, chapter navigation that knows where the
/// boundaries are, and a position that means something when it is written back
/// to the server as a fraction of the book rather than of a file.
@Observable
@MainActor
public final class AudiobookCoordinator {
    public enum Source: Sendable {
        /// Tracks streamed from the server, authenticated by cookie.
        case streaming(base: URL, cookies: [HTTPCookie])
        /// A file already on disk, played whole.
        case local(URL)
    }

    public let manifest: AudiobookManifest
    public let player: AudioPlayer
    public private(set) var trackIndex = 0
    /// Seconds into the whole book, not into the current file.
    public private(set) var bookTime: TimeInterval = 0

    /// Called when the playing chapter changes, for Now Playing and the UI.
    public var onChapterChange: ((Int) -> Void)?
    /// Called only when a chapter *ended* — the audio ran off the end of one
    /// track into the next. Not for a chapter the listener picked, nor a
    /// scrub that crossed a boundary.
    ///
    /// The sleep timer's "end of chapter" hangs off this and nothing else.
    /// It used to hang off `onChapterChange`, which every track load fires,
    /// so picking a chapter from the list stopped the book and disarmed the
    /// timer. The read-along coordinator draws the same line.
    public var onChapterChangeObserved: (() -> Void)?

    private let source: Source
    /// Increments per load so a superseded one cannot write back.
    private var loadGeneration = 0

    public init(manifest: AudiobookManifest, source: Source, player: AudioPlayer = AudioPlayer()) {
        self.manifest = manifest
        self.source = source
        self.player = player

        player.onTimeUpdate = { [weak self] time in
            guard let self, time.isFinite else { return }
            let candidate = manifest.startTime(ofTrackAt: trackIndex) + time
            // Belt as well as braces. The book clock is what Now Playing
            // publishes and what every skip is measured from, so nothing
            // non-finite may enter it — a single NaN latched here and never
            // cleared itself.
            guard candidate.isFinite else { return }
            bookTime = candidate
        }
        // Tracks are contiguous: the end of one is the start of the next, and a
        // listener should hear no seam at a chapter boundary.
        player.onFinishedFile = { [weak self] in
            guard let self else { return }
            Task { await self.advance() }
        }
    }

    public var tracks: [AudiobookManifest.Track] { manifest.playableTracks }
    public var totalDuration: TimeInterval { manifest.totalDuration }
    public var isEmpty: Bool { tracks.isEmpty }

    /// Fraction of the whole book, for a scrubber and for the saved position.
    public var progress: Double {
        guard totalDuration > 0, bookTime.isFinite else { return 0 }
        // An explicit gate, not incidental comparison semantics: Swift's
        // min/max return the other operand when a comparison with NaN is false,
        // so `min(max(NaN, 0), 1)` is NaN, not 0.
        return min(max(bookTime / totalDuration, 0), 1)
    }

    /// The current track's extent on the book clock.
    ///
    /// Cached against the track index because `startTime(ofTrackAt:)` reduces
    /// over a computed filter — O(n) and allocating — and a scrubber asks for
    /// this on every tick.
    private var cachedTrackSpan: (index: Int, start: TimeInterval, duration: TimeInterval)?

    var trackSpan: (start: TimeInterval, duration: TimeInterval)? {
        let index = trackIndex
        guard tracks.indices.contains(index),
              let duration = tracks[index].duration, duration > 0
        else { return nil }
        if let cached = cachedTrackSpan, cached.index == index {
            return (cached.start, cached.duration)
        }
        let start = manifest.startTime(ofTrackAt: index)
        cachedTrackSpan = (index, start, duration)
        return (start, duration)
    }

    public var chapterTitle: String {
        guard tracks.indices.contains(trackIndex) else { return "" }
        return manifest.title(of: tracks[trackIndex], at: trackIndex)
    }

    // MARK: - Playback

    /// Starts, or resumes, at a fraction of the whole book.
    public func start(atProgress progress: Double = 0) async {
        defer { steeredAt = false }
        // See ReadalongCoordinator: a NaN survived the inline clamp and was
        // then written back as a chosen position.
        guard let place = progress.asProgression else { return }
        await seek(toBookTime: totalDuration * place)
        player.play()
    }

    public func seek(toBookTime time: TimeInterval) async {
        guard let (index, offset) = manifest.locate(bookTime: time) else { return }
        if index != trackIndex || player.currentAudioHref == nil {
            await load(track: index, startAt: offset)
        } else {
            await player.seek(to: offset)
        }
        bookTime = manifest.startTime(ofTrackAt: index) + offset
    }

    /// Set when the listener steered, cleared when the answer is read.
    ///
    /// The fifteen-second position writer is a timer and cannot know a scrub
    /// happened, so the coordinator — which owns every seek entry point —
    /// records it instead. Deliberately not set by `start(atProgress:)`: resuming
    /// a book is the app choosing a place, not the listener.
    private var steeredAt: Bool = false

    /// Whether the listener has steered since this was last asked.
    public func consumeSteering() -> Bool {
        defer { steeredAt = false }
        return steeredAt
    }

    public func seek(toProgress progress: Double) async {
        steeredAt = true
        // See ReadalongCoordinator: a NaN survived the inline clamp and was
        // then written back as a chosen position.
        guard let place = progress.asProgression else { return }
        await seek(toBookTime: totalDuration * place)
    }

    public func play(chapter index: Int) async {
        steeredAt = true
        guard tracks.indices.contains(index) else { return }
        await load(track: index, startAt: 0)
        player.play()
    }

    /// Moves a whole chapter, or back to the start of this one.
    ///
    /// Restarting the current chapter when a few seconds in is what every audio
    /// player does, and what a listener who taps "previous" by reflex means.
    public func nextChapter() async {
        // Refuse at the end rather than clamp. `min` on the last track resolved
        // to the *current* track, restarting it at zero — and because
        // `play(chapter:)` marks the move as steered, the position writer sent
        // that backwards jump to the server as `.chosen`, the one origin
        // PositionGuard never refuses. The read-along's `moveChapter` already
        // refuses at the boundary; this is the same contract.
        guard tracks.indices.contains(trackIndex + 1) else { return }
        await play(chapter: trackIndex + 1)
    }

    public func previousChapter() async {
        steeredAt = true
        if player.currentTime > 3 {
            await player.seek(to: 0)
            // Every other seek path — `seek(toBookTime:)`, `load(track:startAt:)`
            // — updates `bookTime` itself; this was the one that didn't; a skip
            // fired right after restarting a chapter computed its target from
            // wherever playback had been a moment ago, not from the restart.
            bookTime = manifest.startTime(ofTrackAt: trackIndex)
        } else {
            await play(chapter: max(trackIndex - 1, 0))
        }
    }

    /// Skips within the book rather than within the file, so a skip near a
    /// chapter boundary crosses it instead of stopping dead at the edge.
    public func skip(by delta: TimeInterval) async {
        steeredAt = true
        // Refuse rather than guess. With a non-finite clock the clamp below
        // collapsed to exactly 0, so both rewind and fast-forward threw the
        // listener back to the start of the book — and the position writer then
        // persisted that zero.
        guard bookTime.isFinite, totalDuration > 0 else { return }
        await seek(toBookTime: max(0, min(bookTime + delta, totalDuration)))
    }

    /// Applies a mapped control action, so the lock screen, headphones, CarPlay
    /// and steering-wheel buttons all funnel through one place.
    public func perform(_ action: PlaybackAction, using map: CommandMap) async {
        switch action {
        case .playPause:
            player.togglePlayPause()
        case .skipForward:
            await skip(by: map.skipForwardInterval)
        case .skipBackward:
            await skip(by: -map.skipBackwardInterval)
        case .nextChapter:
            await nextChapter()
        case .previousChapter:
            await previousChapter()
        // An audiobook has no sentence or paragraph structure to step through,
        // so those map to the nearest thing that exists rather than doing
        // nothing at all when a wheel button is pressed in the car.
        case .nextSentence, .nextParagraph:
            await skip(by: map.skipForwardInterval)
        case .previousSentence, .previousParagraph:
            await skip(by: -map.skipBackwardInterval)
        case .speedUp:
            player.rate = Float(PlaybackRate.clamped(Double(player.rate) + PlaybackRate.step))
        case .speedDown:
            player.rate = Float(PlaybackRate.clamped(Double(player.rate) - PlaybackRate.step))
        // Discrete on purpose, never a toggle: the system sends these when it
        // has already decided which one it means, and its idea of the state —
        // the published rate — can lag `isPlaying` through a stall.
        case .play:
            player.play()
        case .pause:
            player.pause()
        case .sleepTimer, .none:
            break
        }
    }

    // MARK: - Plumbing

    private func advance() async {
        guard trackIndex + 1 < tracks.count else {
            player.pause()
            return
        }
        guard await load(track: trackIndex + 1, startAt: 0) else { return }
        // The one place a chapter genuinely ends, so the one place the sleep
        // timer is told.
        onChapterChangeObserved?()
        // Only if the boundary left it playing. An "end of chapter" sleep
        // timer pauses in the call above, and an unconditional play() here
        // undid that pause in the same turn, after the timer had already
        // reset itself, so the rest of the book played on into the night.
        guard player.isPlaying else { return }
        player.play()
    }

    /// - Returns: whether this load still owned the state when it finished;
    ///   false when a newer one overtook it.
    @discardableResult
    private func load(track index: Int, startAt offset: TimeInterval) async -> Bool {
        guard tracks.indices.contains(index) else { return false }
        // One load at a time. Two interleaved loads left `trackIndex` and
        // `bookTime` set by whichever coroutine resumed last while the audio
        // came from whichever insert won, which is the one way the book clock
        // could genuinely disagree with the playing track.
        let generation = loadGeneration &+ 1
        loadGeneration = generation

        let track = tracks[index]
        trackIndex = index
        // Corrected BEFORE the await, not after: a publish during the load used
        // to report the start of the target track and silently drop the offset.
        bookTime = manifest.startTime(ofTrackAt: index) + offset
        switch source {
        case let .streaming(base, cookies):
            // Hrefs in the manifest are relative to the listen directory.
            let url = base.appending(path: track.href)
            await player.load(url: url, href: track.href, startAt: offset, cookies: cookies)
        case let .local(url):
            await player.load(url: url, href: track.href, startAt: offset)
        }
        // A newer load started while this one was awaiting; it owns the state.
        guard loadGeneration == generation else { return false }
        bookTime = manifest.startTime(ofTrackAt: index) + offset
        onChapterChange?(index)
        return true
    }
}
