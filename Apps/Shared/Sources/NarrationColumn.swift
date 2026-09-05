import Foundation

/// The two decisions the read-along column makes before it draws anything: how
/// many lines a sentence may take, and how many sentences to show either side
/// of the spoken one.
///
/// Both are the television's, and both would naturally live beside
/// `TVReadalongView`. They are here instead because `Apps/Shared` compiles into
/// the iOS target and the iOS target is the only one with a test bundle — the
/// tvOS target has none. The arithmetic that decides whether a reader sees a
/// whole sentence or one ending in an ellipsis is worth asserting, and a
/// SwiftUI `body` cannot be.
enum NarrationColumn {
    /// How many lines a sentence may use before it truncates.
    ///
    /// The spoken line gets four because it is the one being read; its
    /// neighbours get three. Both numbers were set by looking at a television
    /// rather than by arithmetic: at three and two, a long neighbour still
    /// ended in an ellipsis with a third of the column standing empty below
    /// it, which is the complaint this whole change exists to answer. Beyond
    /// these a sentence does truncate, and that is the "unless it won't fit on
    /// the screen" case — the alternative is shrinking type that is being read
    /// from across a room.
    static func lineAllowance(isCurrent: Bool) -> Int { isCurrent ? 4 : 3 }

    /// The window narrowed to `neighbours` sentences either side of the spoken
    /// one.
    ///
    /// This is what the column sheds when it runs short of height. Dropping
    /// context is recoverable — the reader still sees the sentence being
    /// spoken, whole — where clipping words is not.
    ///
    /// Clamped at both ends, so a sentence near the start or the end of a
    /// chapter returns fewer neighbours rather than trapping. A window with no
    /// current line is returned untouched: there is nothing to centre on, and
    /// silently emptying the column would read as a broken screen.
    static func trimmed(
        _ lines: [ReaderModel.NarratedLine], neighbours: Int
    ) -> [ReaderModel.NarratedLine] {
        guard !lines.isEmpty, neighbours >= 0 else { return lines }
        guard let current = lines.firstIndex(where: \.isCurrent) else { return lines }
        let lower = max(0, current - neighbours)
        let upper = min(lines.count - 1, current + neighbours)
        return Array(lines[lower ... upper])
    }
}
