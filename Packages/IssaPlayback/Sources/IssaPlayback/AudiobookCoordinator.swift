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

    private let source: Source

    public init(manifest: AudiobookManifest, source: Source, player: AudioPlayer = AudioPlayer()) {
        self.manifest = manifest
        self.source = source
        self.player = player

        player.onTimeUpdate = { [weak self] time in
            guard let self else { return }
            bookTime = manifest.startTime(ofTrackAt: trackIndex) + time
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
        guard totalDuration > 0 else { return 0 }
        return min(max(bookTime / totalDuration, 0), 1)
    }

    public var chapterTitle: String {
        guard tracks.indices.contains(trackIndex) else { return "" }
        return manifest.title(of: tracks[trackIndex], at: trackIndex)
    }

    // MARK: - Playback

    /// Starts, or resumes, at a fraction of the whole book.
    public func start(atProgress progress: Double = 0) async {
        await seek(toBookTime: totalDuration * min(max(progress, 0), 1))
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

    public func seek(toProgress progress: Double) async {
        await seek(toBookTime: totalDuration * min(max(progress, 0), 1))
    }

    public func play(chapter index: Int) async {
        guard tracks.indices.contains(index) else { return }
        await load(track: index, startAt: 0)
        player.play()
    }

    /// Moves a whole chapter, or back to the start of this one.
    ///
    /// Restarting the current chapter when a few seconds in is what every audio
    /// player does, and what a listener who taps "previous" by reflex means.
    public func nextChapter() async {
        await play(chapter: min(trackIndex + 1, tracks.count - 1))
    }

    public func previousChapter() async {
        if player.currentTime > 3 {
            await player.seek(to: 0)
        } else {
            await play(chapter: max(trackIndex - 1, 0))
        }
    }

    /// Skips within the book rather than within the file, so a skip near a
    /// chapter boundary crosses it instead of stopping dead at the edge.
    public func skip(by delta: TimeInterval) async {
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
            player.rate = min(player.rate + 0.25, 5.0)
        case .speedDown:
            player.rate = max(player.rate - 0.25, 0.5)
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
        await load(track: trackIndex + 1, startAt: 0)
        player.play()
    }

    private func load(track index: Int, startAt offset: TimeInterval) async {
        guard tracks.indices.contains(index) else { return }
        let track = tracks[index]
        trackIndex = index
        switch source {
        case let .streaming(base, cookies):
            // Hrefs in the manifest are relative to the listen directory.
            let url = base.appending(path: track.href)
            await player.load(url: url, href: track.href, startAt: offset, cookies: cookies)
        case let .local(url):
            await player.load(url: url, href: track.href, startAt: offset)
        }
        bookTime = manifest.startTime(ofTrackAt: index) + offset
        onChapterChange?(index)
    }
}
