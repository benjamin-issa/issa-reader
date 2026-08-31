import Foundation

/// How much of a book a progress bar stands for.
///
/// The whole book is the honest default, but for a five-hour audiobook it makes
/// a chapter a sliver you cannot aim at, and "3:49:09 remaining" answers a
/// question nobody asked while listening to chapter seventeen.
public enum ProgressScope: String, Codable, Sendable, CaseIterable, Hashable {
    case book
    case chapter

    public var title: String {
        switch self {
        case .book: "Whole book"
        case .chapter: "This chapter"
        }
    }
}

/// What a progress bar shows, and what dragging it means.
///
/// A value rather than three computations, because the same numbers have to
/// appear on the player, on the mini bar's hairline, on the Lock Screen and in
/// the car, and a bar that disagrees with its own times is worse than one that
/// is merely coarse. It is also the inverse: `bookProgress(forFraction:)` turns
/// a drag back into a position, so the surface that drew the bar is the one
/// that says what a drag on it meant.
///
/// Pure, so every case that matters — a book with no chapters, a chapter of
/// zero length, a duration that has not loaded yet — can be tested rather than
/// discovered in a car.
public struct PlaybackProgress: Sendable, Equatable {
    /// Whether the visible span is a chapter rather than the whole book.
    public let isChapterScoped: Bool
    /// Where the visible span begins on the book clock, and how long it runs.
    public let spanStart: TimeInterval
    public let spanDuration: TimeInterval
    public let bookDuration: TimeInterval
    public let bookProgress: Double

    public init(
        scope: ProgressScope,
        bookProgress: Double,
        totalDuration: TimeInterval,
        chapterSpan: (start: TimeInterval, duration: TimeInterval)?,
    ) {
        let total = totalDuration.isFinite && totalDuration > 0 ? totalDuration : 0
        self.bookProgress = bookProgress.isFinite ? min(max(bookProgress, 0), 1) : 0
        bookDuration = total

        // Falls back to the whole book whenever a chapter cannot be described:
        // a single-file audiobook, a read-along whose document has no narration,
        // a manifest still loading. Degrading to a coarse bar is right; dividing
        // by zero is not.
        if scope == .chapter, total > 0, let span = chapterSpan,
           span.duration > 0, span.start.isFinite, span.duration.isFinite {
            isChapterScoped = true
            spanStart = max(0, span.start)
            spanDuration = min(span.duration, total - max(0, span.start))
        } else {
            isChapterScoped = false
            spanStart = 0
            spanDuration = total
        }
    }

    /// Time into the visible span.
    public var elapsed: TimeInterval {
        guard spanDuration > 0 else { return 0 }
        return min(max(bookProgress * bookDuration - spanStart, 0), spanDuration)
    }

    public var remaining: TimeInterval {
        max(spanDuration - elapsed, 0)
    }

    /// Where the thumb sits, 0...1 of the visible span.
    public var fraction: Double {
        spanDuration > 0 ? elapsed / spanDuration : 0
    }

    /// The book position a drag to `fraction` of this bar means.
    public func bookProgress(forFraction fraction: Double) -> Double {
        guard bookDuration > 0 else { return 0 }
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        let time = spanStart + clamped * spanDuration
        return min(max(time / bookDuration, 0), 1)
    }

    /// The book position a Lock Screen scrub to `seconds` means.
    ///
    /// iOS reports the drag in the same units as the duration it was given, so
    /// this has to be the inverse of whatever `elapsed`/`spanDuration` were
    /// published — otherwise a drag on a chapter-scoped bar lands somewhere else
    /// entirely in the book.
    public func bookProgress(forSeconds seconds: TimeInterval) -> Double {
        guard spanDuration > 0 else { return 0 }
        return bookProgress(forFraction: seconds / spanDuration)
    }
}
