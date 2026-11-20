import Foundation
import Testing

@testable import IssaReader_iOS

/// The decisions a window makes for a link naming a book, with no window.
@Suite("Opening the book a link names")
@MainActor
struct BookLinkFlowTests {
    private static func request(_ uuid: String, serial: Int) -> AppModel.PendingBook {
        AppModel.PendingBook(uuid: uuid, destination: .read, serial: serial)
    }

    private static func situation(
        _ pending: AppModel.PendingBook?, reader: String? = nil, owner: Bool = true,
        library: Bool = true, sheet: Bool = false,
    ) -> BookLinkFlow.Situation {
        BookLinkFlow.Situation(
            pending: pending, libraryHasBook: library, visibleReader: reader,
            isOwner: owner, mayHaveSheet: sheet)
    }

    private static func token(_ step: BookLinkFlow.Step) -> Int {
        switch step {
        case let .closeCovers(_, token), let .settle(token), let .closeSheetsThenSettle(token): token
        default: -1
        }
    }

    @Test("a link with nothing up is routed at once")
    func routesAtOnce() {
        var flow = BookLinkFlow()
        #expect(flow.evaluate(Self.situation(Self.request("b", serial: 1))) == .route)
    }

    @Test("a link waits for the library before closing anything")
    func waitsForTheLibrary() {
        var flow = BookLinkFlow()
        #expect(flow.evaluate(Self.situation(Self.request("b", serial: 1), reader: "a", library: false)) == .nothing)
    }

    @Test("a link for the book on screen is dropped")
    func dropsTheBookOnScreen() {
        var flow = BookLinkFlow()
        #expect(flow.evaluate(Self.situation(Self.request("a", serial: 1), reader: "a")) == .discard)
    }

    @Test("another book's reader is closed, waited out, and only then is the page pushed")
    func closesThenSettlesThenRoutes() {
        var flow = BookLinkFlow()
        let b = Self.request("b", serial: 1)
        let close = flow.evaluate(Self.situation(b, reader: "a"))
        #expect(close == .closeCovers(reader: "a", token: Self.token(close)))
        // Still up: nothing yet.
        #expect(flow.evaluate(Self.situation(b, reader: "a")) == .nothing)
        // Gone: a beat for the dismissal.
        let settle = flow.evaluate(Self.situation(b))
        guard case .settle = settle else { Issue.record("expected a settle, got \(settle)"); return }
        #expect(flow.settleElapsed(token: Self.token(settle), Self.situation(b)) == .route)
        #expect(flow.phase == .idle)
    }

    /// The two timers used to be independent: the fallback could fire during
    /// the settle and push mid-dismissal.
    @Test("the close timeout does nothing once the reader has gone")
    func timeoutDuringSettleIsIgnored() {
        var flow = BookLinkFlow()
        let b = Self.request("b", serial: 1)
        let close = flow.evaluate(Self.situation(b, reader: "a"))
        let settle = flow.evaluate(Self.situation(b))
        #expect(flow.closeTimedOut(token: Self.token(close), Self.situation(b)) == .nothing)
        #expect(flow.settleElapsed(token: Self.token(settle), Self.situation(b)) == .route)
    }

    /// A reader that never reports gone must not be pushed under.
    @Test("a reader that will not go is asked twice and the link is given up, never routed")
    func aStuckReaderIsNeverPushedUnder() {
        var flow = BookLinkFlow()
        let b = Self.request("b", serial: 1)
        let first = flow.evaluate(Self.situation(b, reader: "a"))
        let second = flow.closeTimedOut(token: Self.token(first), Self.situation(b, reader: "a"))
        guard case .closeCovers = second else { Issue.record("expected a second close, got \(second)"); return }
        let last = flow.closeTimedOut(token: Self.token(second), Self.situation(b, reader: "a"))
        #expect(last == .giveUp)
        #expect(flow.phase == .idle)
    }

    @Test("a link for another book during the settle waits for the same dismissal")
    func newerLinkDuringSettleWaits() {
        var flow = BookLinkFlow()
        let b = Self.request("b", serial: 1)
        let c = Self.request("c", serial: 2)
        _ = flow.evaluate(Self.situation(b, reader: "a"))
        let settleB = flow.evaluate(Self.situation(b))
        let settleC = flow.evaluate(Self.situation(c))
        guard case .settle = settleC else { Issue.record("routed mid-dismissal: \(settleC)"); return }
        // B's timer belongs to a request that has gone.
        #expect(flow.settleElapsed(token: Self.token(settleB), Self.situation(c)) == .nothing)
        #expect(flow.settleElapsed(token: Self.token(settleC), Self.situation(c)) == .route)
    }

    /// The reader for A was asked to close for B; A's link then arrived and
    /// was dropped as "already open", and A's reader closed anyway.
    @Test("a link for the book whose reader is closing reopens it afterwards")
    func linkForTheClosingBookIsNotDropped() {
        var flow = BookLinkFlow()
        let b = Self.request("b", serial: 1)
        let a = Self.request("a", serial: 2)
        _ = flow.evaluate(Self.situation(b, reader: "a"))
        let again = flow.evaluate(Self.situation(a, reader: "a"))
        guard case .closeCovers(reader: "a", _) = again else { Issue.record("expected a close, got \(again)"); return }
        let settle = flow.evaluate(Self.situation(a))
        #expect(flow.settleElapsed(token: Self.token(settle), Self.situation(a)) == .route)
    }

    @Test("a player sheet with no reader is closed and waited out before the page")
    func aSheetIsClosedFirst() {
        var flow = BookLinkFlow()
        let b = Self.request("b", serial: 1)
        let step = flow.evaluate(Self.situation(b, sheet: true))
        guard case .closeSheetsThenSettle = step else { Issue.record("expected sheets closed, got \(step)"); return }
        #expect(flow.settleElapsed(token: Self.token(step), Self.situation(b, sheet: true)) == .route)
    }

    @Test("a window that does not own the request does nothing and keeps nothing")
    func otherWindowsLeaveItAlone() {
        var owner = BookLinkFlow()
        var other = BookLinkFlow()
        let b = Self.request("b", serial: 1)
        let close = owner.evaluate(Self.situation(b, reader: "a"))
        #expect(other.evaluate(Self.situation(b, reader: "a", owner: false)) == .nothing)
        #expect(other.phase == .idle)
        // The owner routes; the request is spent and the other window, asked
        // again, holds nothing that could swallow an identical link.
        let settle = owner.evaluate(Self.situation(b))
        #expect(owner.settleElapsed(token: Self.token(settle), Self.situation(b)) == .route)
        #expect(other.evaluate(Self.situation(nil, owner: false)) == .nothing)
        _ = close
        // An identical link again is a new request, and is handled afresh.
        let again = Self.request("b", serial: 2)
        #expect(owner.evaluate(Self.situation(again, reader: "a")) != .nothing)
    }

    @Test("two links in a row for the same book are different requests")
    func serialsDistinguishIdenticalLinks() {
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        app.requestBook("b", .read)
        let first = app.pendingBook
        app.requestBook("b", .read)
        #expect(first != app.pendingBook)
    }

    @Test("the first window to ask owns the request, and a closed window gives it up")
    func theFirstWindowOwns() {
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        app.requestBook("b", .read)
        let request = app.pendingBook!
        let one = UUID(), two = UUID()
        #expect(app.claimBookLink(request, for: one))
        #expect(!app.claimBookLink(request, for: two))
        #expect(app.claimBookLink(request, for: one))
        app.releaseBookLinks(of: one)
        #expect(app.claimBookLink(request, for: two))
        // A newer request is anyone's.
        app.requestBook("b", .read)
        #expect(app.claimBookLink(app.pendingBook!, for: one))
    }

    @Test("a window in the background does not take a request while another is in the foreground")
    func backgroundWindowsDoNotClaim() {
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        app.requestBook("b", .read)
        let request = app.pendingBook!
        let behind = UUID(), front = UUID()
        app.window(behind, isInForeground: false)
        app.window(front, isInForeground: true)
        #expect(!app.claimBookLink(request, for: behind))
        #expect(app.claimBookLink(request, for: front))
    }

    @Test("with no window in the foreground, any window may take it")
    func anyWindowWhenNoneIsInFront() {
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        app.requestBook("b", .read)
        #expect(app.claimBookLink(app.pendingBook!, for: UUID()))
    }
}
