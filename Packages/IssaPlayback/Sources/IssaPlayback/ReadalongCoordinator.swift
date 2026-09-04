import AVFoundation
import Foundation
import IssaCore
import IssaEPUB
import Observation

/// Keeps narration and text in step.
///
/// The audio clock is the source of truth. A periodic observer keeps the model
/// honest at a modest rate, and the view interpolates between observations, so
/// the highlight looks continuous without waking the CPU on every frame while
/// the screen is off.
@Observable
@MainActor
public final class ReadalongCoordinator {
    public private(set) var activeFragmentID: String?
    public private(set) var activeEntry: SMILEntry?
    /// Progress through the whole book, 0...1, on the virtual gapless timeline.
    public private(set) var bookProgress: Double = 0

    /// Called when the highlight moves to a fragment in a different chapter, so
    /// the reader can load and turn to it.
    public var onChapterChange: ((String) -> Void)?
    /// A second, independent chapter-boundary hook.
    ///
    /// The reader owns `onChapterChange` to turn the page; the sleep timer needs
    /// the same signal for "end of chapter" and must not have to fight it.
    public var onChapterChangeObserved: (() -> Void)?
    /// Called whenever the highlighted fragment changes.
    public var onFragmentChange: ((String) -> Void)?
    /// Called when something other than the clock moved the playhead — a tapped
    /// sentence, the scrubber, a skip, a chapter command.
    ///
    /// The reader uses it to tell a position the listener *chose* from one
    /// narration merely wandered into. Notably `play(from:)` does not fire it:
    /// pressing play asks for audio, it does not name a place, and when the app
    /// has to work out where that is the guess must not be allowed to overwrite
    /// a known-good position.
    ///
    /// Fired *after* the move, and only when something moved. Announcing the
    /// seek first meant every early return behind it — the end of the book, a
    /// missing audio file, a skip with no anchor yet — left the reader told of
    /// a choice that never happened.
    public var onSeek: (() -> Void)?

    public let player: AudioPlayer
    private let timeline: SMILTimeline
    /// Archive href to the extracted file on disk.
    private let audioFiles: [String: URL]

    public init(timeline: SMILTimeline, audioFiles: [String: URL], player: AudioPlayer = AudioPlayer()) {
        self.timeline = timeline
        self.audioFiles = audioFiles
        self.player = player

        player.onTimeUpdate = { [weak self] time in
            self?.advance(to: time)
        }
        player.onFinishedFile = { [weak self] in
            Task { await self?.advanceToNextFile() }
        }
    }

    public var isEmpty: Bool { timeline.isEmpty }
    public var totalDuration: TimeInterval { timeline.totalDuration }

    // MARK: - Clock

    /// Maps the player's position within the current file onto a fragment.
    ///
    /// Scoped to the current file: clip times restart at zero in each track, so
    /// a book-time search here would land on the wrong sentence.
    private func advance(to time: TimeInterval) {
        guard let href = player.currentAudioHref,
              let entry = timeline.entry(inFile: href, at: time)
        else { return }

        if entry.fragmentID != activeFragmentID {
            let previousDocument = activeEntry?.textHref
            activeFragmentID = entry.fragmentID
            activeEntry = entry
            onFragmentChange?(entry.fragmentID)
            if entry.textHref != previousDocument {
                onChapterChange?(entry.textHref)
                // Only a real boundary, not the first fragment of a session.
                if previousDocument != nil { onChapterChangeObserved?() }
            }
        }
        // Book progress uses the virtual timeline so it advances smoothly across
        // chapter and track boundaries.
        let elapsedWithin = max(0, time - entry.start)
        bookProgress = timeline.progression(
            atBookTime: entry.cumulativeEnd - entry.duration + elapsedWithin,
        )
    }

    private func advanceToNextFile() async {
        guard let entry = activeEntry, let next = timeline.entry(after: entry) else {
            player.pause()
            return
        }
        await play(from: next)
    }

    // MARK: - Seeking

    /// Starts (or continues) playback at a specific narrated fragment.
    ///
    /// - Returns: whether it moved there. False when the entry's audio file is
    ///   missing, in which case nothing plays either.
    @discardableResult
    public func play(from entry: SMILEntry) async -> Bool {
        guard await move(to: entry) else { return false }
        player.play()
        return true
    }

    /// `play(from:)` for a place the listener named: the seek is announced once
    /// the move has happened, and not at all if it did not.
    private func jump(to entry: SMILEntry) async {
        if await play(from: entry) { onSeek?() }
    }

    /// Moves the playhead and the highlight without touching whether audio is
    /// playing. False when the entry's audio file is missing and nothing moved.
    ///
    /// Split out of `play(from:)` because `seek(toBookProgress:)` is a protocol
    /// requirement with a neutral contract — the audiobook implementation moves
    /// the playhead and nothing else — and routing a Lock Screen scrub through
    /// `play(from:)` made a paused book start reading itself aloud in a quiet
    /// room, from the scrubber, the skip buttons and the macOS key commands
    /// alike.
    @discardableResult
    private func move(to entry: SMILEntry) async -> Bool {
        if player.currentAudioHref != entry.audioHref {
            guard let url = audioFiles[entry.audioHref] else { return false }
            await player.load(url: url, href: entry.audioHref, startAt: entry.start)
        } else {
            await player.seek(to: entry.start)
        }
        activeFragmentID = entry.fragmentID
        activeEntry = entry
        // Set here rather than left to the time observer: a paused player's
        // clock does not tick, so without this a paused scrub never reached
        // the scrubber or the Lock Screen.
        bookProgress = timeline.progression(atBookTime: entry.cumulativeEnd - entry.duration)
        onFragmentChange?(entry.fragmentID)
        return true
    }

    public func seek(toFragment fragmentID: String) async {
        guard let entry = timeline.entry(forFragment: fragmentID) else { return }
        await jump(to: entry)
    }

    /// Seeks by fraction of the whole book, for a scrubber.
    /// Skips within the BOOK, not within the current audio file.
    ///
    /// `AudioPlayer.skip` moves the playhead inside whichever file is loaded and
    /// clamps at that file's zero, so a fifteen-second rewind five seconds into
    /// a file landed at the start of the file rather than ten seconds earlier in
    /// the book — while the elapsed time published to the lock screen was
    /// book-wide. The audiobook coordinator already worked this way; this is the
    /// same contract for narration.
    public func skipBook(by delta: TimeInterval) async {
        let total = totalDuration
        guard total > 0 else { return }
        // Refuse rather than guess when narration has never played: the
        // coordinator is built eagerly on open and the reader footer draws the
        // skip buttons regardless, so with no anchor a skip resolved to
        // sentence one of the whole book — a third of a novel away from the
        // reader. The same contract as the audiobook's skip from a broken
        // clock.
        guard let entry = activeEntry else { return }
        // Anchored to the active entry and the player's own clock, not to
        // `bookProgress`: that field is written only by the periodic observer,
        // so in the first moments after `play(from:)` it still reads 0.
        let within = min(max(0, player.currentTime - entry.start), entry.duration)
        let current = entry.cumulativeEnd - entry.duration + within
        guard current.isFinite else { return }
        await seek(toBookProgress: max(0, min(current + delta, total)) / total)
    }

    public func seek(toBookProgress progress: Double) async {
        // A non-finite progress is not a place in the book. Refusing it is
        // the point: the inline clamp let NaN through, `totalDuration * NaN`
        // is NaN, and the seek that followed set `steeredAt`, so the position
        // writer persisted the result as a listener-*chosen* position — the one
        // origin PositionGuard may not refuse.
        guard let place = progress.asProgression else { return }
        let time = timeline.totalDuration * place
        guard let entry = timeline.entry(atBookTime: time) else { return }
        // A seek is not a play button: it lands paused when paused, playing
        // when playing, exactly as the audiobook implementation of this same
        // protocol method always has.
        if await move(to: entry) { onSeek?() }
    }

    // MARK: - Actions

    /// Applies a mapped control action. This is the single funnel every surface
    /// goes through — screen, lock screen, headphones, CarPlay and the wheel —
    /// so a remapping applies everywhere at once.
    public func perform(_ action: PlaybackAction, using map: CommandMap) async {
        // Navigation names a place; playing, speed and the sleep timer do not.
        // Each navigation route announces its own seek, after it has moved.
        switch action {
        case .playPause:
            player.togglePlayPause()
        case .skipForward:
            await skipBook(by: map.skipForwardInterval)
        case .skipBackward:
            await skipBook(by: -map.skipBackwardInterval)
        case .nextSentence:
            if let entry = activeEntry, let next = timeline.entry(after: entry) { await jump(to: next) }
        case .previousSentence:
            if let entry = activeEntry, let previous = timeline.entry(before: entry) { await jump(to: previous) }
        case .nextParagraph:
            await moveParagraph(forward: true)
        case .previousParagraph:
            await moveParagraph(forward: false)
        case .nextChapter:
            await moveChapter(forward: true)
        case .previousChapter:
            await moveChapter(forward: false)
        case .speedUp:
            player.rate = min(player.rate + 0.25, 5.0)
        case .speedDown:
            player.rate = max(player.rate - 0.25, 0.5)
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

    /// A paragraph boundary is approximated by a run of sentences: the aligner
    /// numbers sentences per chapter, so stepping several sentences is the
    /// closest reliable equivalent without re-parsing the source markup.
    private static let sentencesPerParagraph = 3

    private func moveParagraph(forward: Bool) async {
        guard var entry = activeEntry else { return }
        for _ in 0 ..< Self.sentencesPerParagraph {
            guard let next = forward ? timeline.entry(after: entry) : timeline.entry(before: entry) else { break }
            entry = next
        }
        await jump(to: entry)
    }

    private func moveChapter(forward: Bool) async {
        guard let current = activeEntry else { return }
        let documents = timeline.entries.map(\.textHref).reduce(into: [String]()) { list, href in
            if list.last != href { list.append(href) }
        }
        guard let index = documents.firstIndex(of: current.textHref) else { return }
        let target = forward ? index + 1 : index - 1
        guard documents.indices.contains(target),
              let entry = timeline.firstEntry(inDocument: documents[target])
        else { return }
        await jump(to: entry)
    }
}

extension ReadalongCoordinator: PlaybackDriving {
    /// A readaloud's chapter name lives in the book's navigation document, not
    /// in the timeline, so the reader supplies it; the timeline knows only
    /// which text document is playing.
    public var currentChapterTitle: String { activeEntry?.textHref ?? "" }

    /// The current text document's extent on the virtual book timeline.
    ///
    /// The timeline precomputes these, so this is a dictionary lookup rather
    /// than a walk over every entry in the book.
    public var chapterSpan: (start: TimeInterval, duration: TimeInterval)? {
        guard let href = activeEntry?.textHref else { return nil }
        return timeline.span(ofDocument: href)
    }
}
