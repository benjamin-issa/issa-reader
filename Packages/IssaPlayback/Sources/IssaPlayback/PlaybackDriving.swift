import Foundation

/// What every playback surface needs, whichever kind of book is playing.
///
/// A readaloud is driven by a SMIL timeline and an audiobook by a track list,
/// but the player sheet, the Now Playing centre, CarPlay and the mini player
/// all want the same handful of things. Naming that here keeps every surface
/// from branching on the kind of book — and it is why the audiobook path gets
/// remapped controls and a sleep timer for free.
/// What a playback rate may be.
///
/// One statement of the range, because there were six and they disagreed three
/// ways. The bound controls — a headphone command, the macOS Playback menu —
/// walked to 5.0× and down to 0.5×, speeds that appear in *no* menu anywhere
/// and that the transport renders as "5×"; the rate menus offer 0.75 to 3.0;
/// CarPlay's cycle stops at 2.0. And `PlaybackSettings.playbackRate` clamped
/// nothing, so a 5.0 reached by holding a button was persisted and restored on
/// the next launch, with no control able to show it.
///
/// The offered ladder is what the menus already list; the bounds are its ends.
/// This is not a merge of the six sites — each still owns its own control — but
/// they now agree about what is legal.
public enum PlaybackRate {
    public static let ladder: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    public static let step: Double = 0.25
    public static var minimum: Double { ladder.first ?? 0.75 }
    public static var maximum: Double { ladder.last ?? 3.0 }

    /// The nearest legal rate. Non-finite and out-of-range values included:
    /// this is read from persisted defaults and from a remote-command event,
    /// neither of which is under this app's control.
    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return Swift.min(Swift.max(value, minimum), maximum)
    }
}

@MainActor
public protocol PlaybackDriving: AnyObject {
    var player: AudioPlayer { get }
    /// Fraction of the whole book, not of the current file.
    var bookProgress: Double { get }
    var totalDuration: TimeInterval { get }
    /// The chapter now playing, or an empty string when there is no structure.
    var currentChapterTitle: String { get }
    /// Where the current chapter begins on the book clock, and how long it runs.
    ///
    /// Nil where the book has no chapters the coordinator can describe — a
    /// single-file audiobook, a read-along in an unaligned document — and every
    /// caller falls back to the whole book rather than guessing.
    var chapterSpan: (start: TimeInterval, duration: TimeInterval)? { get }
    func seek(toBookProgress progress: Double) async
    func perform(_ action: PlaybackAction, using map: CommandMap) async
}

extension AudiobookCoordinator: PlaybackDriving {
    public var bookProgress: Double { progress }
    public var currentChapterTitle: String { chapterTitle }
    public var chapterSpan: (start: TimeInterval, duration: TimeInterval)? { trackSpan }
    public func seek(toBookProgress progress: Double) async {
        await seek(toProgress: progress)
    }
}

/// Whether a coordinator's idea of "the chapter" is something to show a reader.
///
/// It often is not. A read-along coordinator has no table of contents — only the
/// text document the current sentence lives in — so `currentChapterTitle` hands
/// back an archive path like `OEBPS/8960978148133687104_chapter_11.xhtml`. The
/// player sheet already knew to hide that; the mini bar did not, and printed it
/// under the book's title where the chapter name belongs.
public enum ChapterNaming {
    public static func isDisplayable(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // A path, or a file. Both are how a document href looks, and neither is
        // a name anybody wrote.
        guard !trimmed.contains("/"), !trimmed.hasSuffix(".xhtml"),
              !trimmed.hasSuffix(".html"), !trimmed.hasSuffix(".xml")
        else { return false }
        return true
    }
}

public extension PlaybackDriving {
    /// The chapter now playing, when there is a real name for it.
    var displayChapterTitle: String? {
        ChapterNaming.isDisplayable(currentChapterTitle) ? currentChapterTitle : nil
    }
}
