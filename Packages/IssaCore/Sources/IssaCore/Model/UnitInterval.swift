import Foundation

public extension Double {
    /// This value as a progression through a book: finite, and between 0 and 1.
    ///
    /// `min(max(x, 0), 1)` does not do this, and was written inline at twenty
    /// production sites — fourteen of them with no finiteness check in front.
    /// Swift's `max(_:_:)` is `y >= x ? y : x`, and every comparison against
    /// NaN is false, so `max(.nan, 0)` returns **NaN** and the clamp passes it
    /// straight through. (Argument order decides it: `max(0, .nan)` returns 0.
    /// Depending on which way round a call happened to be written is not a
    /// guard.)
    ///
    /// `AudiobookCoordinator.progress` already gets this right and carries the
    /// comment explaining why; this is that reasoning made reusable, so the
    /// next site cannot get it wrong by writing the operands the other way
    /// round.
    ///
    /// - Returns: the clamped value, or `nil` when there is no honest answer.
    ///   `nil` rather than 0: a NaN is not "the start of the book", and
    ///   silently saving it as one is how a reader's place was lost.
    var asProgression: Double? {
        guard isFinite else { return nil }
        return Swift.min(Swift.max(self, 0), 1)
    }

    /// The same clamp, for callers with a sensible default and nothing to
    /// report — a progress bar's width, say, where 0 is the right answer for a
    /// value that means nothing.
    func clampedToUnitInterval(orElse fallback: Double = 0) -> Double {
        asProgression ?? fallback
    }
}
