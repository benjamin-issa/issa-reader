import Foundation

/// Why a position write happened.
///
/// This is the only thing that separates a legitimate step backwards from a
/// destructive one. Readers move backwards constantly — a page, a chapter, a
/// bookmark, a search hit, the scrubber, starting a finished book again — so a
/// rule that refuses every smaller progression is not a safety net, it is a
/// second bug.
///
/// What does hold is whether the reader named the **destination**. The word is
/// load-bearing: pressing play is the reader's doing, but *where playback
/// resumes* is the app's, and that is precisely the write that destroyed a place
/// in a part-read novel. A rule keyed on "the user initiated something" would
/// have classified that tap as intentional and let it through.
public enum PositionOrigin: String, Sendable, Hashable, Codable {
    /// The reader named the place: a page turn, a Contents entry, a bookmark, a
    /// search hit, a tapped sentence, the scrubber, the skip controls. Any
    /// distance, in any direction, is legitimate.
    case chosen
    /// Somewhere a clock arrived at: the narration highlight moving on, the
    /// audiobook's periodic writer, a chapter loaded because the audio crossed
    /// into it, or a resume position the app resolved on the reader's behalf.
    /// Forward is expected; a long step back is a bug.
    case derived
}

/// Refuses a position write that would move a reader backwards without their
/// having asked for it.
///
/// A pure value with no clock and no I/O, so the rule can be tested exhaustively
/// — including the cases that must *not* be blocked, which matter more than the
/// one that must.
public struct PositionGuard: Sendable, Hashable {
    /// The furthest point reached since the reader last chose where to be.
    ///
    /// A high-water mark rather than the last value written: a wrong position
    /// rarely arrives alone, and one small step back, then another, then another
    /// walks a book out from under a "compare with the previous write" rule
    /// while every individual step looks innocent.
    public private(set) var highWater: Double

    /// Total narration in seconds, where the book has any. Used only to tighten
    /// the tolerance on very long audiobooks.
    public let duration: TimeInterval?

    public enum Decision: Sendable, Hashable, Equatable {
        case allow
        case refuse(held: Double, candidate: Double)

        public var isAllowed: Bool { self == .allow }
    }

    /// The largest step backwards a clock may take on its own: five per cent of
    /// the book, or five minutes of narration, whichever is smaller.
    ///
    /// Both sit far above anything legitimate — a thirty-second skip back, a
    /// player resuming a few seconds early after an interruption, and the
    /// highlight re-anchoring at a chapter boundary are all much smaller — and
    /// far below a regression that destroys a reading place, which by definition
    /// is most of the book.
    static let fractionTolerance = 0.05
    /// Five per cent of a forty-hour audiobook is two hours of undetected slack,
    /// so long books are held to a tighter absolute bound.
    static let secondsTolerance: TimeInterval = 300

    public init(highWater: Double = 0, duration: TimeInterval? = nil) {
        self.highWater = min(max(highWater.isFinite ? highWater : 0, 0), 1)
        self.duration = duration
    }

    var tolerance: Double {
        guard let duration, duration > 0 else { return Self.fractionTolerance }
        return min(Self.fractionTolerance, Self.secondsTolerance / duration)
    }

    /// Whether this write may proceed, updating the mark if it may.
    public mutating func decide(_ candidate: Double?, origin: PositionOrigin) -> Decision {
        // No progression is not a claim about where the reader is.
        guard let candidate else { return .allow }
        guard candidate.isFinite, candidate >= 0, candidate <= 1 else {
            return .refuse(held: highWater, candidate: candidate)
        }
        if origin == .chosen {
            // *To* the candidate, not the larger of the two: someone who has
            // just restarted a finished book must be able to read its first
            // chapter without every page being measured against the ending.
            highWater = candidate
            return .allow
        }
        guard candidate >= highWater - tolerance else {
            return .refuse(held: highWater, candidate: candidate)
        }
        highWater = max(highWater, candidate)
        return .allow
    }
}
