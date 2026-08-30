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
