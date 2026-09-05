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
    /// The spoken line gets three because it is the one being read; its
    /// neighbours get two, which covers all but a long sentence and keeps the
    /// column's height within reach of a 1080-point screen. Beyond three lines
    /// in the 48-point face — roughly 180 characters — a sentence does end in
    /// an ellipsis, which is the "unless it won't fit on the screen" case. The
    /// alternative is shrinking type that is read from across a room.
    static func lineAllowance(isCurrent: Bool) -> Int { isCurrent ? 3 : 2 }

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
