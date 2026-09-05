import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// The rules around a reader's place, which is the one thing this app cannot
/// recover once it is wrong.
@Suite("Reading position")
@MainActor
struct PositionWritingTests {
    static let uuid = "11111111-1111-4111-8111-111111111111"

    /// The guard for this book's *reading* position.
    ///
    /// Guards are keyed by book and by clock — the reader's text progression
    /// and the audiobook's audio progression are separate high-water marks,
    /// because they are fractions of different timelines. Through the
    /// production helper, so a change to the key cannot leave these green while
    /// `reseedGuards` quietly matches nothing.
    static var textGuardKey: String {
        AppModel.positionGuardKey(uuid, isAudioScaled: false)
    }

    /// `PositionGuard` does re-baseline — but only on `.chosen`. Nothing
    /// re-seeded it when a refresh legitimately adopted a *lower* server
    /// position, so every `.derived` write afterwards was refused for the rest
    /// of the process and the reader's progress was persisted nowhere.
    ///
    /// Through `AppModel.reseedGuards`, the production function. The first
    /// version of this test built a fresh `PositionGuard(highWater: 0.02)` by
    /// hand and asserted on it — so emptying `reseedGuards` left it green,
    /// which the second review demonstrated.
    @Test("a guard whose book moved backwards on the server stops refusing")
    func guardFollowsTheServerBackwards() throws {
        let app = AppModel()
        app.positionGuards[Self.textGuardKey] = PositionGuard(highWater: 0.85, duration: 40 * 3600)

        // Where it was before: a derived write from chapter one is refused.
        var before = try #require(app.positionGuards[Self.textGuardKey])
        #expect(before.decide(0.02, origin: .derived).isRefusal)

        // The server now says 0.02 — the book was restarted elsewhere.
        app.reseedGuards(against: [SharedFixtures.book("Dracula", uuid: Self.uuid, progress: 0.02)])

        var after = try #require(app.positionGuards[Self.textGuardKey])
        #expect(abs(after.highWater - 0.02) < 0.0001, "the guard was not re-seeded from the server")
        #expect(!after.decide(0.03, origin: .derived).isRefusal, "reading on must be recordable")
    }

    /// Only a move *backwards* re-seeds. A server that is further ahead is the
    /// ordinary case — this device is behind — and the high-water mark must
    /// keep refusing the stale derived writes it exists to refuse.
    @Test("a guard whose book moved forwards on the server is left alone")
    func forwardMoveDoesNotReseed() throws {
        let app = AppModel()
        app.positionGuards[Self.textGuardKey] = PositionGuard(highWater: 0.85, duration: 40 * 3600)

        app.reseedGuards(against: [SharedFixtures.book("Dracula", uuid: Self.uuid, progress: 0.90)])

        let after = try #require(app.positionGuards[Self.textGuardKey])
        #expect(abs(after.highWater - 0.85) < 0.0001, "a forward move must not lower the mark")
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
