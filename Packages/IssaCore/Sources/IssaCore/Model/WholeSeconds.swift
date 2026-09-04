import Foundation

public extension Double {
    /// This many seconds as a whole number, or `nil` when there is no honest
    /// answer.
    ///
    /// `Int(_:)` **traps** on a value outside `Int`'s range, and `isFinite` does
    /// not bound magnitude — `1e300` is finite, and `Int(1e300.rounded())` is an
    /// uncatchable crash rather than a wrong number. Every duration this is
    /// asked about comes from a server response or from an audio file's own
    /// metadata, so neither a NaN nor an absurd magnitude is hypothetical: the
    /// clock formatters that guarded `isFinite` and stopped there were one
    /// malformed `media:duration` away from taking the app down on the book
    /// screen.
    ///
    /// `Int(exactly:)` covers both in one test — it returns nil for a NaN, an
    /// infinity and anything out of range — which is why this exists rather
    /// than a second `isFinite` at each site.
    ///
    /// - Returns: the rounded value, or nil. `nil` rather than 0, so a caller
    ///   showing a clock can say nothing instead of claiming "0:00".
    var wholeSeconds: Int? {
        Int(exactly: rounded())
    }
}
