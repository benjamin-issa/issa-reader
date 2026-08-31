import Foundation

/// What every playback surface needs, whichever kind of book is playing.
///
/// A readaloud is driven by a SMIL timeline and an audiobook by a track list,
/// but the player sheet, the Now Playing centre, CarPlay and the mini player
/// all want the same handful of things. Naming that here keeps every surface
/// from branching on the kind of book — and it is why the audiobook path gets
/// remapped controls and a sleep timer for free.
@MainActor
public protocol PlaybackDriving: AnyObject {
    var player: AudioPlayer { get }
    /// Fraction of the whole book, not of the current file.
    var bookProgress: Double { get }
    var totalDuration: TimeInterval { get }
    /// The chapter now playing, or an empty string when there is no structure.
    var currentChapterTitle: String { get }
    func seek(toBookProgress progress: Double) async
    func perform(_ action: PlaybackAction, using map: CommandMap) async
}

extension AudiobookCoordinator: PlaybackDriving {
    public var bookProgress: Double { progress }
    public var currentChapterTitle: String { chapterTitle }
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
