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
        /// One file per track, keyed by `Track.href` — the archive path the
        /// media overlay names and `AudioAnchor` carries.
        ///
        /// `.local` cannot stand in: it hands the *same* URL to every track, so
        /// a manifest synthesised over a book's hundred and seventy-six
        /// narration chunks would play chunk one under every one of them while
        /// the book clock counted on regardless.
        case files([String: URL])
    }

    public let manifest: AudiobookManifest
    public let player: AudioPlayer
    public private(set) var trackIndex = 0
    /// Seconds into the whole book, not into the current file.
    public private(set) var bookTime: TimeInterval = 0

    /// The places in this book a listener would call chapters.
    ///
    /// Not the tracks. For the server's own upload the two coincide and this is
    /// built from the track list, which is exactly today's behaviour; for a
    /// manifest synthesised over a read-along's narration chunks a chapter
    /// starts wherever the overlay says, which is usually part-way into a file.
    /// Everything that shows a chapter — Now Playing, the scrubber, CarPlay's
    /// Up Next, the sleep timer's "end of chapter" — reads this rather than
    /// `trackIndex`.
    public let chapters: [AudiobookChapter]
    /// Which of them is playing.
    public private(set) var chapterIndex = 0
    /// Where each chapter begins on the book clock. Computed once: it is read
    /// on every tick, and `startTime(ofTrackAt:)` reduces over a computed
    /// filter.
    ///
    /// **Strictly ascending**, which is a promise the chapter list itself does
    /// not make. An overlay that revisits a chunk gives a later chapter an
    /// earlier track — `ChunkManifest.fileOrder` records each file at its first
    /// appearance and must, or one file would answer to two stretches of book
    /// clock — and starts of `[0, 9, 5]` broke every reader of them at once:
    /// the binary search below returned chapter one for a time inside chapter
    /// three, `chapterSpan` computed `5 - 9` and handed the scrubber the whole
    /// book instead, and `nextChapter()` seeked *backwards* and marked it
    /// `.chosen`, the one origin `PositionGuard` never refuses.
    private let chapterStarts: [TimeInterval]
    /// How many loads are between choosing a track and having loaded it.
    ///
    /// A load moves `trackIndex` and `bookTime` before it awaits, and the
    /// player's periodic observer keeps firing across the change with the *old*
    /// item's time. Announcing a chapter off that arithmetic is announcing one
    /// the listener is not in, so the clock is ignored until the load settles.
    private var loadsInFlight = 0
    /// How many seeks are between the clock moving and the audio following it.
    ///
    /// `loadsInFlight`'s twin, for the branch that loads nothing: a scrub
    /// inside the current file never reaches `load`, so nothing counted it,
    /// and the player's periodic observer keeps firing across the await.
    ///
    /// The clock and the chapter are set before that await — see
    /// `seek(toBookTime:)` — which already makes a sample carrying the *post*-
    /// seek time harmless. This is for the one carrying a *pre*-seek time: it
    /// drags the announced chapter back to where the scrub started, which fires
    /// nothing on its own because going backwards is never an ending, and then
    /// the next honest sample reads that as an advance and hands the sleep
    /// timer an "end of chapter" in the middle of a deliberate skip.
    ///
    /// Internal rather than private so a test can see the window it opens.
    var seeksInFlight = 0

    /// Called when the playing chapter changes, for Now Playing and the UI.
    ///
    /// Carries the chapter index, which is an index into `chapters` and no
    /// longer a track index — the two differ the moment a chapter starts
    /// mid-file.
    public var onChapterChange: ((Int) -> Void)?
    /// Called only when a chapter *ended* — the audio ran off the end of one
    /// chapter into the next under the listener. Not for a chapter the listener
    /// picked, nor a scrub that crossed a boundary.
    ///
    /// A chapter, not a file. A book played from its own narration chunks
    /// crosses a file boundary every couple of minutes; only some of those are
    /// chapter boundaries, and only some chapter boundaries are file boundaries
    /// at all — see `AudiobookChapter`.
    ///
    /// The sleep timer's "end of chapter" hangs off this and nothing else.
    /// It used to hang off `onChapterChange`, which every track load fires,
    /// so picking a chapter from the list stopped the book and disarmed the
    /// timer. The read-along coordinator draws the same line.
    public var onChapterChangeObserved: (() -> Void)?

    private let source: Source
    /// Increments per load so a superseded one cannot write back.
    private var loadGeneration = 0

    /// - Parameter chapters: where this book's chapters start. Empty — the
    ///   default, and what every caller playing the server's own manifest
    ///   passes — means one chapter per playable track, named as the manifest
    ///   names it, which is what this class did before chapters and tracks
    ///   could differ. An entry naming a track this manifest does not have is
    ///   dropped rather than trusted: the chapter list and the track list are
    ///   built by different code, and an out-of-range index would trap on the
    ///   first tick. So is one that does not start after the chapter in front of
    ///   it — see `chapterStarts`.
    public init(
        manifest: AudiobookManifest,
        source: Source,
        chapters: [AudiobookChapter] = [],
        player: AudioPlayer = AudioPlayer(),
    ) {
        self.manifest = manifest
        self.source = source
        self.player = player

        let playable = manifest.playableTracks
        let inRange = chapters.filter { playable.indices.contains($0.trackIndex) }
        let candidates = inRange.isEmpty
            ? playable.enumerated().map { index, track in
                AudiobookChapter(title: manifest.title(of: track, at: index), trackIndex: index)
            }
            : inRange
        // One at a time, keeping only the chapters that move the clock forward.
        // Not a fallback to one chapter per track: a book with one bad boundary
        // still has forty good ones, and throwing them away would cost the
        // listener every chapter marker to fix a marker they never asked for.
        var kept: [AudiobookChapter] = []
        var starts: [TimeInterval] = []
        for chapter in candidates {
            let start = manifest.startTime(ofTrackAt: chapter.trackIndex) + chapter.offset
            guard start.isFinite, starts.last.map({ start > $0 }) ?? (start >= 0) else {
                IssaLog.warning("chapter does not start after the one before it", [
                    "chapter": String(kept.count),
                    "start": String(format: "%.1f", start),
                    "previousStart": String(format: "%.1f", starts.last ?? 0),
                ])
                continue
            }
            kept.append(chapter)
            starts.append(start)
        }
        self.chapters = kept
        chapterStarts = starts

        player.onTimeUpdate = { [weak self] time in
            guard let self, time.isFinite else { return }
            let candidate = manifest.startTime(ofTrackAt: trackIndex) + time
            // Belt as well as braces. The book clock is what Now Playing
            // publishes and what every skip is measured from, so nothing
            // non-finite may enter it — a single NaN latched here and never
            // cleared itself.
            guard candidate.isFinite else { return }
            bookTime = candidate
            syncChapter(fromTick: true)
        }
        // Tracks are contiguous: the end of one is the start of the next, and a
        // listener should hear no seam at a chapter boundary.
        player.onFinishedFile = { [weak self] in
            guard let self else { return }
            Task { await self.advance() }
        }
    }

    public var tracks: [AudiobookManifest.Track] { manifest.playableTracks }

    /// Where the audiobook is, in terms the read-along engine can also act on.
    ///
    /// The other half of `AudioAnchor`'s bridge — see `ReadalongCoordinator`'s
    /// property of the same name. A track and an offset into it, which is what
    /// this engine natively knows and what the media overlay can be matched
    /// against, so the two clocks never have to be converted by arithmetic.
    public var currentAnchor: AudioAnchor? {
        // Nothing has been loaded, so there is nowhere to name. `trackIndex` is
        // zero from birth and `bookTime` with it, so without this a coordinator
        // that never played a note answered "chunk one, offset zero" — which is
        // the ordinary outcome when the `.files` source refuses a chunk, and
        // which `ListeningHandoff.Skip.noAnchor`'s own doc already claims is
        // impossible. `ReadalongCoordinator.currentAnchor` makes that promise
        // through `activeEntry`; this is the same promise, through the one
        // thing that says a file was actually opened. `attachListening` reads
        // the same property for the same reason.
        guard player.currentAudioHref != nil else { return nil }
        let all = tracks
        guard all.indices.contains(trackIndex) else { return nil }
        let start = manifest.startTime(ofTrackAt: trackIndex)
        // Derived from the book clock rather than read off the player, so it
        // agrees with whatever this coordinator last published — the player's
        // own time is per-item and briefly zero across a track change.
        let within = bookTime - start
        guard within.isFinite else { return nil }
        return AudioAnchor(
            audioHref: all[trackIndex].href,
            offset: within,
            writtenAt: Date().timeIntervalSince1970,
        )
    }
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

    /// The current chapter's extent on the book clock.
    ///
    /// The chapter, not the file it happens to start in: a scrubber scoped to
    /// the chapter runs from one chapter marker to the next, and on a
    /// synthesised manifest a chapter spans several chunks and begins inside
    /// one. Cached against the chapter index because a scrubber asks for this
    /// on every tick and the arithmetic below allocates.
    private var cachedChapterSpan: (index: Int, start: TimeInterval, duration: TimeInterval)?

    public var chapterSpan: (start: TimeInterval, duration: TimeInterval)? {
        let index = chapterIndex
        guard chapters.indices.contains(index) else { return nil }
        if let cached = cachedChapterSpan, cached.index == index {
            return (cached.start, cached.duration)
        }
        let start = chapterStarts[index]
        // The next chapter's start, or the end of the book for the last one.
        let end = chapterStarts.indices.contains(index + 1)
            ? chapterStarts[index + 1]
            : totalDuration
        let duration = end - start
        guard duration > 0 else { return nil }
        cachedChapterSpan = (index, start, duration)
        return (start, duration)
    }

    public var chapterTitle: String {
        guard chapters.indices.contains(chapterIndex) else { return "" }
        return chapters[chapterIndex].title
    }

    /// The chapter playing at a point on the book clock: the last one that
    /// starts at or before it. Binary search, because a tick asks per second.
    private func chapterIndex(atBookTime time: TimeInterval) -> Int {
        guard !chapterStarts.isEmpty else { return 0 }
        var low = 0
        var high = chapterStarts.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if chapterStarts[mid] <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Brings the announced chapter into line with the book clock.
    ///
    /// - Parameter fromTick: whether this came from the player's clock rather
    ///   than from a load or a seek. **A tick may never move into a later
    ///   file.** Every duration a media overlay can offer is an estimate — the
    ///   last clip ends a beat before the file does — so a stated duration
    ///   shorter than the real one leaves the clock running past the track
    ///   boundary while that same file is still playing, and the listener would
    ///   be told the next chapter had begun before a word of it was spoken.
    ///   Only `advance()` moves between files, so only `advance()` may announce
    ///   a chapter that lives in the next one.
    private func syncChapter(fromTick: Bool) {
        // Mid-load the clock describes neither the old file nor the new one,
        // and mid-seek it describes neither where the listener was nor where
        // they asked to go.
        guard loadsInFlight == 0, seeksInFlight == 0 else { return }
        var index = chapterIndex(atBookTime: bookTime)
        if fromTick {
            while index > 0, chapters[index].trackIndex > trackIndex { index -= 1 }
        }
        guard index != chapterIndex else { return }
        let advanced = index > chapterIndex
        chapterIndex = index
        onChapterChange?(index)
        // A chapter that *ended* under the listener, which is the one thing the
        // sleep timer waits for. Going backwards is a scrub, not an ending.
        if fromTick, advanced { onChapterChangeObserved?() }
    }

    // MARK: - Playback

    /// Starts, or resumes, at a fraction of the whole book.
    public func start(atProgress progress: Double = 0) async {
        defer { steeredAt = false }
        // See ReadalongCoordinator: a NaN survived the inline clamp and was
        // then written back as a chosen position.
        guard let place = progress.asProgression else { return }
        // Not `play()` regardless. With one file per track a missing chunk is a
        // real outcome — a half-deleted extraction, a book whose download went
        // while it sat paused — and calling play on a player holding nothing
        // leaves a book that claims to be playing in silence, which is what the
        // fifteen-second writer then persists progress against.
        guard await seek(toBookTime: totalDuration * place) else { return }
        player.play()
    }

    /// - Returns: whether audio is now positioned where it was asked to be.
    ///   False when the time names no track, or when the load that would have
    ///   reached it did not happen.
    @discardableResult
    public func seek(toBookTime time: TimeInterval) async -> Bool {
        guard let (index, offset) = manifest.locate(bookTime: time) else { return false }
        if index != trackIndex || player.currentAudioHref == nil {
            // `load` sets the clock and the chapter itself, and is the only one
            // of the two branches that can decline.
            return await load(track: index, startAt: offset)
        }
        // Both BEFORE the await, for the reason `load` corrects its own clock
        // before one: the player's periodic observer keeps firing across the
        // seek, and a tick that lands mid-seek is answered against whatever
        // this coordinator has already published. Left until afterwards, the
        // post-seek time arrived while the chapter was still the pre-seek one,
        // so the tick — not the scrub — announced the crossing, `advanced` was
        // true, and a deliberate skip reached the sleep timer as "the chapter
        // ended" and paused the book mid-skip.
        bookTime = manifest.startTime(ofTrackAt: index) + offset
        // A scrub inside one file can still cross a chapter boundary — chunks
        // are cut by silence, chapters by the book — but crossing one this way
        // is the listener steering, not a chapter ending.
        syncChapter(fromTick: false)
        // And the clock ignored for the length of the seek, exactly as it is
        // for the length of a load. Belt as well as braces: the lines above
        // answer the sample that arrives holding the new time, this one the
        // sample that arrives still holding the old. Counted rather than
        // flagged, because two scrubs in a burst overlap and the second must
        // not reopen the clock while the first is still in flight.
        seeksInFlight += 1
        defer { seeksInFlight -= 1 }
        await player.seek(to: offset)
        return true
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
        guard chapters.indices.contains(index) else { return }
        let chapter = chapters[index]
        // Into the chapter's own start, which on a synthesised manifest is part
        // of the way into its chunk. Loading the track at zero would land the
        // listener at the end of the *previous* chapter.
        guard await load(track: chapter.trackIndex, startAt: chapter.offset) else { return }
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
        guard chapters.indices.contains(chapterIndex + 1) else { return }
        await play(chapter: chapterIndex + 1)
    }

    public func previousChapter() async {
        steeredAt = true
        guard chapterStarts.indices.contains(chapterIndex) else { return }
        let start = chapterStarts[chapterIndex]
        // Measured against the chapter's start on the book clock, not against
        // the player's position in the file. A chapter that begins mid-chunk is
        // already several seconds into its file when it starts, so the player's
        // own clock would report "well into this chapter" the instant it began
        // and "previous" would restart a chapter nobody had heard yet.
        if bookTime - start > 3 {
            await seek(toBookTime: start)
        } else {
            await play(chapter: max(chapterIndex - 1, 0))
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
        let before = chapterIndex
        guard await load(track: trackIndex + 1, startAt: 0) else { return }
        // Only when the *chapter* changed, not whenever a file did. A book
        // synthesised over narration chunks crosses a file boundary every couple
        // of minutes and a chapter boundary every half hour; telling the sleep
        // timer that the first was the second ended the book at the next chunk,
        // which is nowhere a listener would have chosen to stop.
        if chapterIndex != before { onChapterChangeObserved?() }
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
        let track = tracks[index]
        // Resolved before a single piece of state moves. A `.files` track with
        // no file is a refusal, not a load, and the old order — index and clock
        // first, then find something to play — would have left the coordinator
        // claiming to be in a track it never reached, with the book clock and
        // every position written from it counting through silence.
        let destination: (url: URL, cookies: [HTTPCookie])
        switch source {
        case let .streaming(base, cookies):
            // Hrefs in the manifest are relative to the listen directory.
            destination = (base.appending(path: track.href), cookies)
        case let .local(url):
            destination = (url, [])
        case let .files(files):
            guard let url = files[track.href] else {
                IssaLog.warning("audio chunk has no file", [
                    "href": track.href, "track": String(index),
                ])
                player.pause()
                return false
            }
            destination = (url, [])
        }

        // One load at a time. Two interleaved loads left `trackIndex` and
        // `bookTime` set by whichever coroutine resumed last while the audio
        // came from whichever insert won, which is the one way the book clock
        // could genuinely disagree with the playing track.
        let generation = loadGeneration &+ 1
        loadGeneration = generation

        trackIndex = index
        // Corrected BEFORE the await, not after: a publish during the load used
        // to report the start of the target track and silently drop the offset.
        bookTime = manifest.startTime(ofTrackAt: index) + offset
        loadsInFlight += 1
        defer { loadsInFlight -= 1 }
        await player.load(
            url: destination.url, href: track.href,
            startAt: offset, cookies: destination.cookies,
        )
        // A newer load started while this one was awaiting; it owns the state.
        guard loadGeneration == generation else { return false }
        bookTime = manifest.startTime(ofTrackAt: index) + offset
        // Unconditionally, as every load has always published: Now Playing
        // rebuilds from this and a reloaded track is a new item there whether or
        // not the chapter around it changed.
        chapterIndex = chapterIndex(atBookTime: bookTime)
        onChapterChange?(chapterIndex)
        return true
    }
}
