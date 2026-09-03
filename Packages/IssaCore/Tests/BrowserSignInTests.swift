import Foundation
import Testing

@testable import IssaCore

/// A browser that never closes on its own — which is what a real one does. It
/// comes off the screen only when the flow cancels it.
private actor ScriptedBrowser: ApprovalBrowsing {
    /// What `present` returns if it is allowed to finish rather than cancelled.
    private let dismissal: BrowserDismissal?
    private(set) var presented: [URL] = []
    private(set) var wasCancelled = false

    init(dismissal: BrowserDismissal? = nil) { self.dismissal = dismissal }

    func present(_ url: URL) async -> BrowserDismissal {
        presented.append(url)
        if let dismissal { return dismissal }
        // Wait to be cancelled, the way an open Safari sheet does.
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
            }
        } onCancel: {}
        await noteCancellation()
        return .byApp
    }

    private func noteCancellation() { wasCancelled = true }
}

/// The device-grant side, scripted. Separate from `DeviceGrantTests`' copy so
/// the two suites cannot drift into each other's expectations.
private actor ScriptedPollTransport: DeviceGrantTransport {
    private var results: [DevicePollResult]
    private let complete: String?
    private(set) var pollCount = 0
    private let failStart: Bool

    init(results: [DevicePollResult], complete: String? = "http://example.test/device?device_code=dev-code", failStart: Bool = false) {
        self.results = results
        self.complete = complete
        self.failStart = failStart
    }

    func start() async throws -> DeviceAuthorization {
        if failStart { throw StorytellerError.transport("no route to host") }
        return DeviceAuthorization(
            deviceCode: "dev-code",
            userCode: "ABCD-EFGH",
            verificationURI: "http://example.test/device",
            verificationURIComplete: complete,
            expiresIn: 900,
            interval: 5,
            qrSVGURL: nil,
        )
    }

    func poll(deviceCode: String) async -> DevicePollResult {
        pollCount += 1
        return results.isEmpty ? .error(.authorizationPending) : results.removeFirst()
    }

    /// One scripted second is one millisecond, rather than the no-op wait the
    /// device-grant suite uses.
    ///
    /// The no-op is right where the poll is the only thing running. Here it is
    /// wrong in a way that hides the bug: with an instant clock the poll loop
    /// runs all 180 intervals to its deadline before the browser task gets a
    /// chance to return, so every test of "the browser finished first" silently
    /// tested "the request expired" instead. A real suspension, however short,
    /// makes the ordering deterministic — the browser leg returns without ever
    /// suspending, so it is always first to the group.
    func wait(seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds.rounded())))
    }
}

@Suite("Signing in through the server's own page")
struct BrowserSignInTests {
    private func silently(_ progress: BrowserSignInFlow.Progress) {}

    @Test("the browser is closed the moment the poll returns a token")
    func browserClosesWhenThePollWins() async {
        let transport = ScriptedPollTransport(results: [
            .error(.authorizationPending), .error(.authorizationPending), .token("granted-token"),
        ])
        let browser = ScriptedBrowser()
        let outcome = await BrowserSignInFlow(transport: transport, browser: browser)
            .run(reporting: silently)

        #expect(outcome == .granted("granted-token"))
        // The whole point: a sheet left on screen over a signed-in library.
        #expect(await browser.wasCancelled)
    }

    @Test("closing the browser without approving does not leave the poll running")
    func dismissalStopsThePoll() async {
        // Pending forever. Without the bounded grace window this runs to the
        // server's fifteen-minute deadline — 180 polls — rather than stopping.
        let transport = ScriptedPollTransport(results: [])
        let browser = ScriptedBrowser(dismissal: .byUser)
        let outcome = await BrowserSignInFlow(
            transport: transport, browser: browser, pollsAfterDismissal: 3
        ).run(reporting: silently)

        #expect(outcome == .dismissed)
        #expect(await transport.pollCount <= 4)
    }

    /// The footgun the grace window exists for: the server records the approval
    /// whether the window is still open or not, so a token granted a moment
    /// before the window closed must not be thrown away.
    @Test("an approval that lands as the window closes is not thrown away")
    func approvalRacingTheDismissalIsKept() async {
        let transport = ScriptedPollTransport(results: [.token("late-token")])
        let browser = ScriptedBrowser(dismissal: .byUser)
        let outcome = await BrowserSignInFlow(transport: transport, browser: browser)
            .run(reporting: silently)

        #expect(outcome == .granted("late-token"))
    }

    @Test("a denial during the grace window is reported as a denial")
    func denialAfterDismissal() async {
        let transport = ScriptedPollTransport(results: [.error(.accessDenied)])
        let browser = ScriptedBrowser(dismissal: .byUser)
        let outcome = await BrowserSignInFlow(transport: transport, browser: browser)
            .run(reporting: silently)

        #expect(outcome == .denied)
    }

    @Test("the pre-filled approval URL is what gets opened")
    func opensTheCompleteURL() async {
        let transport = ScriptedPollTransport(results: [.token("t")])
        let browser = ScriptedBrowser()
        _ = await BrowserSignInFlow(transport: transport, browser: browser).run(reporting: silently)

        #expect(await browser.presented
            == [URL(string: "http://example.test/device?device_code=dev-code")!])
    }

    /// Server metadata is not trusted input, and `URL(string:)` builds
    /// `javascript:` as happily as `https:`.
    @Test("a non-web approval URL is never opened")
    func refusesANonWebURL() async {
        let transport = ScriptedPollTransport(results: [.token("t")], complete: "javascript:alert(1)")
        let browser = ScriptedBrowser()
        let outcome = await BrowserSignInFlow(transport: transport, browser: browser)
            .run(reporting: silently)

        guard case let .failed(reason) = outcome else { return #expect(Bool(false)) }
        #expect(reason.contains("web address"))
        #expect(await browser.presented.isEmpty)
    }

    @Test("a browser that cannot open falls out to a sentence")
    func browserThatWillNotOpen() async {
        let transport = ScriptedPollTransport(results: [])
        let browser = ScriptedBrowser(dismissal: .couldNotOpen("Couldn't open your server's sign-in page."))
        let outcome = await BrowserSignInFlow(transport: transport, browser: browser)
            .run(reporting: silently)

        guard case let .failed(reason) = outcome else { return #expect(Bool(false)) }
        #expect(reason.contains("Couldn't open"))
    }

    @Test("a server that will not start a grant says why")
    func startFailure() async {
        let transport = ScriptedPollTransport(results: [], failStart: true)
        let browser = ScriptedBrowser()
        let outcome = await BrowserSignInFlow(transport: transport, browser: browser)
            .run(reporting: silently)

        guard case let .failed(reason) = outcome else { return #expect(Bool(false)) }
        #expect(reason.contains("no route to host"))
        #expect(await browser.presented.isEmpty)
    }

    @Test("progress is reported before the window opens and again while finishing")
    func progressReporting() async {
        let reported = Reported()
        let transport = ScriptedPollTransport(results: [])
        let browser = ScriptedBrowser(dismissal: .byUser)
        _ = await BrowserSignInFlow(transport: transport, browser: browser, pollsAfterDismissal: 1)
            .run { reported.append($0) }

        #expect(reported.values == [.awaitingApproval, .finishing])
    }

    /// Recorded under a lock rather than in an actor reached by a detached
    /// `Task`: the reports are what is being asserted *in order*, and a task per
    /// report is free to deliver them in either.
    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [BrowserSignInFlow.Progress] = []

        var values: [BrowserSignInFlow.Progress] {
            lock.withLock { storage }
        }

        func append(_ value: BrowserSignInFlow.Progress) {
            lock.withLock { storage.append(value) }
        }
    }
}
