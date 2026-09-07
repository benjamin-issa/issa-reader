#if os(tvOS)
import SwiftUI
#endif

/// What the remote is pointing at.
///
/// Here rather than beside `TVPageView` for the same reason as the rule that
/// governs it: the tvOS target has no test bundle, and a focus value declared
/// there is unreachable from any test.
enum TVFocus: Hashable {
    case page
    case transport
}

/// Where a press on the remote's ring leaves focus.
///
/// Pure, and in `Apps/Shared` rather than beside `TVPageView`, because the tvOS
/// target has no test bundle: this compiles into iOS as well, and
/// `IssaSharedTests` runs there.
enum TVFocusMoves {
    /// The four ways a remote can be pushed.
    ///
    /// Not SwiftUI's own `MoveCommandDirection`, which is `@available(iOS,
    /// unavailable)`: a rule stated in it would not compile into the iOS target
    /// at all, and so could not be tested — which is the whole reason this file
    /// is here rather than in the view. The tvOS overload below converts.
    enum Direction: Hashable, Sendable {
        case up
        case down
        case left
        case right
    }

    /// Where a move command should leave the remote. `nil` means stay put.
    ///
    /// Down used to send focus to `.transport` unconditionally. On a book with
    /// no narration that row is not mounted, so focus left `.page` — and
    /// `onMoveCommand` is attached to the page, so the page then stopped
    /// receiving anything at all: Left and Right no longer turned pages, and
    /// Menu, which leaves the book, was the only way out. `.defaultFocus` has
    /// already run by that point and does not fire again.
    ///
    /// The `.down` rule stays `nil` without narration even though the
    /// no-narration row is now a focus target too. The two are answering
    /// different questions: that row exists so the focus *engine* — which moves
    /// focus on a swipe whether or not `onMoveCommand` makes anything of it —
    /// always has somewhere to put focus and somewhere to bring it back from,
    /// while this decides where a deliberate press should go, and a row that
    /// only says "No narration for this book" is not somewhere to send a reader.
    ///
    /// Left and Right answer `nil` because on the page they turn it rather than
    /// move focus, and Up from the page answers `nil` because there is nothing
    /// above it.
    static func destination(
        for direction: Direction, from: TVFocus, hasNarration: Bool,
    ) -> TVFocus? {
        switch (direction, from) {
        case (.down, .page):
            return hasNarration ? .transport : nil
        case (.up, .transport):
            return .page
        default:
            return nil
        }
    }

    #if os(tvOS)
    /// The same rule, taking the direction SwiftUI hands `onMoveCommand`.
    ///
    /// A `default` rather than four cases: `MoveCommandDirection` is a frozen
    /// enum today, and an exhaustive switch that stops compiling if it ever
    /// gains a case is not worth a screen that would be no worse for treating
    /// an unknown push as no push.
    static func destination(
        for direction: MoveCommandDirection, from: TVFocus, hasNarration: Bool,
    ) -> TVFocus? {
        let move: Direction
        switch direction {
        case .up: move = .up
        case .down: move = .down
        case .left: move = .left
        case .right: move = .right
        default: return nil
        }
        return destination(for: move, from: from, hasNarration: hasNarration)
    }
    #endif
}
