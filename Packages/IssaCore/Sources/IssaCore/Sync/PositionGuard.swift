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

    /// Whether this clock is held because the app could not work out, honestly,
    /// where the listener was.
    ///
    /// A high-water mark alone cannot cover that case. Playback that starts at
    /// the beginning because nothing could be resolved sits *below* the mark
    /// only when there is a mark on this clock to sit below — and there is
    /// none, because the stored position was on the other one. So the first
    /// derived write from a resume-at-zero looked like ordinary forward
    /// progress, took the mark with it, and replaced a part-read novel's
    /// position with 0.0001.
    ///
    /// A held clock therefore refuses a derived write carrying *no*
    /// progression too. Such a write makes no claim about where the reader is,
    /// which is why the ordinary rule waves it through — but `recordPosition`
    /// still replaces the stored locator with it, and the stored locator is
    /// the thing being protected. Only the listener naming a place — a
    /// `.chosen` write — releases the hold.
    public private(set) var awaitingChoice: Bool

    public enum Decision: Sendable, Hashable, Equatable {
        case allow
        case refuse(held: Double, candidate: Double)
        /// Refused because this clock is held: the app does not know where the
        /// listener was, and will not guess on their behalf.
        case awaitChoice(candidate: Double?)

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

    public init(highWater: Double = 0, duration: TimeInterval? = nil, awaitingChoice: Bool = false) {
        self.highWater = min(max(highWater.isFinite ? highWater : 0, 0), 1)
        self.duration = duration
        self.awaitingChoice = awaitingChoice
    }

    var tolerance: Double {
        guard let duration, duration > 0 else { return Self.fractionTolerance }
        return min(Self.fractionTolerance, Self.secondsTolerance / duration)
    }

    /// Whether this write may proceed, updating the mark if it may.
    public mutating func decide(_ candidate: Double?, origin: PositionOrigin) -> Decision {
        // Before the nil check on purpose: a held clock refuses a derived write
        // that carries no progression as well, because the write still replaces
        // the stored locator. See `awaitingChoice`.
        if origin == .derived, awaitingChoice { return .awaitChoice(candidate: candidate) }
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
            // And a place named is exactly what a held clock was waiting for.
            awaitingChoice = false
            return .allow
        }
        guard candidate >= highWater - tolerance else {
            return .refuse(held: highWater, candidate: candidate)
        }
        highWater = max(highWater, candidate)
        return .allow
    }
}
