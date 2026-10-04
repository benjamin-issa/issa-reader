import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// Starting a browser sign-in once, however often its screen appears.
///
/// The view starts the flow from `onAppear`, and the browser covers the view
/// the way a full-screen cover does, so its dismissal after a successful
/// callback appears the view a second time. `begin()` used to start over
/// unconditionally: it cancelled the token exchange still in flight, or — with
/// the exchange done and the account being adopted — opened a second browser
/// session that minted a server session nothing would use.
///
/// The flow here is a stand-in the test holds open and releases, so nothing is
/// presented and no network is touched.
@Suite("Beginning a browser sign-in")
@MainActor
struct BrowserSignInBeginTests {
    private static let server = URL(string: "http://192.168.1.10:8001")!

    @Test("a second begin while the first is in flight starts nothing")
    func secondBeginWhileRunning() async throws {
        let flows = HeldFlows()
        let model = BrowserSignInModel(serverURL: Self.server) { _ in await flows.run() }

        model.begin()
        try await flows.waitForStarts(1)
        model.begin()  // The view appearing again as the browser goes.
        try await Task.sleep(for: .milliseconds(200))
        #expect(flows.starts == 1, "the appearance restarted the sign-in")

        flows.finish(.granted("token"))
        try await waitUntil { model.stage == .granted("token") }
        #expect(model.stage == .granted("token"), "the first attempt's token must not be dropped")
    }

    @Test("a begin after the attempt has finished starts nothing")
    func beginAfterFinishing() async throws {
        let flows = HeldFlows()
        let model = BrowserSignInModel(serverURL: Self.server) { _ in await flows.run() }

        model.begin()
        try await flows.waitForStarts(1)
        flows.finish(.granted("token"))
        try await waitUntil { model.stage == .granted("token") }

        model.begin()
        model.cancel()  // As `SignInView.adopt` does once the token is handed over.
        model.begin()
        try await Task.sleep(for: .milliseconds(200))
        #expect(flows.starts == 1)
        #expect(model.stage == .granted("token"))
    }

    @Test("Try again starts a new attempt, and the old one cannot write over it")
    func restartSupersedes() async throws {
        let flows = HeldFlows()
        let model = BrowserSignInModel(serverURL: Self.server) { _ in await flows.run() }

        model.begin()
        try await flows.waitForStarts(1)
        flows.finish(.failed(.couldNotExchange(status: nil)))
        try await waitUntil { if case .failed = model.stage { true } else { false } }

        model.restart()
        try await flows.waitForStarts(2)
        #expect(model.stage == .starting)
        flows.finish(.granted("second"))
        try await waitUntil { model.stage == .granted("second") }
        #expect(model.stage == .granted("second"))
    }

    /// Polls a condition the flow's task settles, for at most two seconds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Stand-in flows: each `run()` counts itself and waits to be told how it
/// ended.
@MainActor
private final class HeldFlows {
    private(set) var starts = 0
    private var waiting: [CheckedContinuation<AppTokenOutcome, Never>] = []

    nonisolated func run() async -> AppTokenOutcome {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.starts += 1
                self.waiting.append(continuation)
            }
        }
    }

    /// Ends the oldest attempt still waiting.
    func finish(_ outcome: AppTokenOutcome) {
        guard !waiting.isEmpty else {
            Issue.record("no attempt is waiting to be finished")
            return
        }
        waiting.removeFirst().resume(returning: outcome)
    }

    func waitForStarts(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while starts < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(starts >= count, "the flow was never started")
    }
}
