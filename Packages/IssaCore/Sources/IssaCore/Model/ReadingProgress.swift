import Foundation

/// How far through a book, said the same way everywhere.
///
/// There is only ever one quantity — `totalProgression`, which the reader
/// computes and the server hands back verbatim — but it used to be *formatted*
/// two ways. The reader's footer and the widget rounded; the book screen and
/// the Continue card truncated. So a book at 13.7% read "14%" in the reader and
/// "13%" everywhere else: an off-by-one that never closed, because it was never
/// staleness.
public enum ReadingProgress {
    /// The whole percent to show a reader.
    ///
    /// Rounded, not truncated. Truncating means a book sits at "99%" through the
    /// whole of its last page, and that a ring drawn from the same value appears
    /// closed while the number beside it disagrees.
    public static func percent(_ progression: Double) -> Int {
        guard progression.isFinite else { return 0 }
        return Int((min(max(progression, 0), 1) * 100).rounded())
    }

    /// The same number as a label: "42%".
    public static func percentText(_ progression: Double) -> String {
        "\(percent(progression))%"
    }
}
