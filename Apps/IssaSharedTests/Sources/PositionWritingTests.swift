import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// The rules around a reader's place, which is the one thing this app cannot
/// recover once it is wrong.
@Suite("Reading position")
@MainActor
struct PositionWritingTests {
    /// `PositionGuard` does re-baseline — but only on `.chosen`. Nothing
    /// re-seeded it when a refresh legitimately adopted a *lower* server
    /// position, so every `.derived` write afterwards was refused for the rest
    /// of the process and the reader's progress was persisted nowhere.
    @Test("a guard whose book moved backwards on the server stops refusing")
    func guardFollowsTheServerBackwards() {
        var state = PositionGuard(highWater: 0.85, duration: 40 * 3600)

        // Where it was before: a derived write from chapter one is refused.
        #expect(state.decide(0.02, origin: .derived).isRefusal)

        // The server now says 0.02 — the book was restarted elsewhere — and the
        // guard is re-seeded from it.
        state = PositionGuard(highWater: 0.02, duration: 40 * 3600)
        #expect(!state.decide(0.03, origin: .derived).isRefusal, "reading on must be recordable")
    }

    /// The tolerance is the smaller of five per cent and five minutes, so a long
    /// audiobook is held to the tighter bound.
    @Test("a small step back is still allowed, a large one is not")
    func toleranceBehaviour() {
        var state = PositionGuard(highWater: 0.5, duration: 3600)
        #expect(!state.decide(0.499, origin: .derived).isRefusal)

        var strict = PositionGuard(highWater: 0.5, duration: 40 * 3600)
        #expect(strict.decide(0.2, origin: .derived).isRefusal)
    }

    /// A chosen write re-baselines downwards by design — restarting a finished
    /// book must not measure every page against the ending.
    @Test("an explicitly chosen position always wins")
    func chosenAlwaysWins() {
        var state = PositionGuard(highWater: 0.99, duration: 3600)
        #expect(!state.decide(0.01, origin: .chosen).isRefusal)
        #expect(!state.decide(0.02, origin: .derived).isRefusal, "and the mark moved with it")
    }
}

private extension PositionGuard.Decision {
    var isRefusal: Bool {
        if case .refuse = self { return true }
        return false
    }
}
