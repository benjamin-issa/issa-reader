import AVFoundation
import Foundation
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
    public func play(from entry: SMILEntry) async {
        if player.currentAudioHref != entry.audioHref {
            guard let url = audioFiles[entry.audioHref] else { return }
            await player.load(url: url, href: entry.audioHref, startAt: entry.start)
        } else {
            await player.seek(to: entry.start)
        }
        activeFragmentID = entry.fragmentID
        activeEntry = entry
        onFragmentChange?(entry.fragmentID)
        player.play()
    }

    public func seek(toFragment fragmentID: String) async {
        guard let entry = timeline.entry(forFragment: fragmentID) else { return }
        await play(from: entry)
    }

    /// Seeks by fraction of the whole book, for a scrubber.
    public func seek(toBookProgress progress: Double) async {
        let time = timeline.totalDuration * min(max(progress, 0), 1)
        guard let entry = timeline.entry(atBookTime: time) else { return }
        await play(from: entry)
    }

    // MARK: - Actions

    /// Applies a mapped control action. This is the single funnel every surface
    /// goes through — screen, lock screen, headphones, CarPlay and the wheel —
    /// so a remapping applies everywhere at once.
    public func perform(_ action: PlaybackAction, using map: CommandMap) async {
        switch action {
        case .playPause:
            player.togglePlayPause()
        case .skipForward:
            await player.skip(by: map.skipForwardInterval)
        case .skipBackward:
            await player.skip(by: -map.skipBackwardInterval)
        case .nextSentence:
            if let entry = activeEntry, let next = timeline.entry(after: entry) { await play(from: next) }
        case .previousSentence:
            if let entry = activeEntry, let previous = timeline.entry(before: entry) { await play(from: previous) }
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
        await play(from: entry)
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
        await play(from: entry)
    }
}
