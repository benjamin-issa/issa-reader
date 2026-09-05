import Foundation
import Testing

@testable import IssaCore

private actor ScriptedBrowser: ApprovalBrowsing {
    private let result: BrowserDismissal
    private(set) var presented: [URL] = []

    init(_ result: BrowserDismissal) { self.result = result }

    func present(_ url: URL) async -> BrowserDismissal {
        presented.append(url)
        return result
    }
}

/// A browser that stays open, the way a real one does.
///
/// `ScriptedBrowser` answers before `run()` has finished starting, so a flow
/// driven by it is never *in progress* — and every fault worth catching here
/// happens while the window is up. Built to the same shape as
/// `BrowserApprovalController`: a continuation held until something resumes it,
/// and a cancellation handler that closes the window and reports `.byApp`.
///
/// A lock rather than an actor, because the cancellation handler is
/// `@Sendable` and nonisolated and must be able to resume the continuation
/// without a hop — which is exactly the constraint the real controller has.
private final class SuspendingBrowser: ApprovalBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<BrowserDismissal, Never>?
    private var presentedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isPresented = false

    func present(_ url: URL) async -> BrowserDismissal {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<BrowserDismissal, Never>) in
                let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                    pending = continuation
                    isPresented = true
                    defer { presentedWaiters.removeAll() }
                    return presentedWaiters
                }
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            resume(with: .byApp)
        }
    }

    /// Returns once the window is actually up, so a test cancels a live flow
    /// rather than racing its start.
    func waitUntilPresented() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already: Bool = lock.withLock {
                if isPresented { return true }
                presentedWaiters.append(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }

    /// The server redirecting back, or the reader closing the window.
    func finish(with dismissal: BrowserDismissal) { resume(with: dismissal) }

    private func resume(with dismissal: BrowserDismissal) {
        let taken: CheckedContinuation<BrowserDismissal, Never>? = lock.withLock {
            defer { pending = nil }
            return pending
        }
        taken?.resume(returning: dismissal)
    }
}

@Suite("Taking a token from the server's own sign-in page")
struct AppTokenSignInTests {
    private let server = URL(string: "http://library.example:8001")!

    @Test("the browser is pointed at the app-token route")
    func opensTheAppTokenRoute() async {
        let browser = ScriptedBrowser(
            .completed(URL(string: "storyteller://settings?token=abc")!))
        _ = await AppTokenSignInFlow(serverURL: server, browser: browser).run()
        #expect(await browser.presented
            == [URL(string: "http://library.example:8001/api/v2/token/app")!])
    }

    /// The shape the server actually sends, recorded from a live 2.14.21 on
    /// 2026-09-04: `302 Location: storyteller://settings?token=<JWT>`.
    @Test("the token comes out of the callback")
    func takesTheToken() async {
        let browser = ScriptedBrowser(
            .completed(URL(string: "storyteller://settings?token=header.payload.signature")!))
        let outcome = await AppTokenSignInFlow(serverURL: server, browser: browser).run()
        #expect(outcome == .granted("header.payload.signature"))
    }

    /// Which of the two it was is carried, not collapsed.
    ///
    /// They look identical to a reader — a browser that appears and vanishes —
    /// and one of them is a bug in this app. Folding them into one `.dismissed`
    /// is how a build shipped in which the app cancelled every sign-in it
    /// started and nothing anywhere said so.
    @Test(
        "closing the window is not an error, and says who closed it",
        arguments: [
            (BrowserDismissal.byUser, AppTokenDismissal.byReader),
            (BrowserDismissal.byApp, AppTokenDismissal.byApp),
        ])
    func dismissal(_ from: BrowserDismissal, _ expected: AppTokenDismissal) async {
        let outcome = await AppTokenSignInFlow(
            serverURL: server, browser: ScriptedBrowser(from)).run()
        #expect(outcome == .dismissed(expected))
    }

    /// The bug this suite could not see.
    ///
    /// `ScriptedBrowser` answers immediately, so the flow was never *running*
    /// when anything could cancel it — and the real failure was that the view
    /// cancelled it one frame after the browser appeared, every single time.
    /// This browser suspends the way a real one does, so the window is open
    /// when the cancel lands.
    @Test("a flow cancelled while the browser is up reports that the app closed it")
    func cancelledWhileOpen() async {
        let browser = SuspendingBrowser()
        let flow = AppTokenSignInFlow(serverURL: server, browser: browser)
        let task = Task { await flow.run() }
        await browser.waitUntilPresented()
        task.cancel()
        #expect(await task.value == .dismissed(.byApp))
    }

    /// And the other half: left alone, the same browser completes.
    ///
    /// Without this the fix above could be "never cancel", which would leave a
    /// browser on screen after the reader had walked away from the route.
    @Test("a flow left alone completes even though the browser takes its time")
    func survivesTheBrowserBeingOpen() async {
        let browser = SuspendingBrowser()
        let flow = AppTokenSignInFlow(serverURL: server, browser: browser)
        let task = Task { await flow.run() }
        await browser.waitUntilPresented()
        browser.finish(with: .completed(URL(string: "storyteller://settings?token=late")!))
        #expect(await task.value == .granted("late"))
    }

    @Test("a callback with no token says so rather than signing nobody in")
    func callbackWithoutAToken() async {
        let browser = ScriptedBrowser(.completed(URL(string: "storyteller://settings")!))
        let outcome = await AppTokenSignInFlow(serverURL: server, browser: browser).run()
        guard case let .failed(failure) = outcome else { return #expect(Bool(false)) }
        #expect(failure == .noToken)
    }

    @Test("a browser that will not open carries its reason through")
    func couldNotOpen() async {
        let browser = ScriptedBrowser(.couldNotOpen("Couldn't open your server's sign-in page."))
        let outcome = await AppTokenSignInFlow(serverURL: server, browser: browser).run()
        guard case let .failed(failure) = outcome else { return #expect(Bool(false)) }
        #expect(failure == .couldNotOpen(reason: "Couldn't open your server's sign-in page."))
    }

    /// `ServerAddress.normalize` only needs a parseable host, so a one-character
    /// typo in the scheme survives it — and `ASWebAuthenticationSession` opens
    /// http and https only. The reader used to be told the *browser* had failed
    /// and steered to a pairing code that would fail identically.
    @Test("an address a browser cannot open is refused before the browser is asked")
    func refusesNonWebAddress() async {
        let browser = ScriptedBrowser(.byUser)
        let outcome = await AppTokenSignInFlow(
            serverURL: URL(string: "htp://library.example")!, browser: browser).run()
        guard case let .failed(failure) = outcome else { return #expect(Bool(false)) }
        #expect(failure == .notAWebAddress)
        #expect(
            await browser.presented.isEmpty,
            "and the browser is never opened at all")
    }

    /// The failure is a case, not a sentence. It said "Try a username and
    /// password" for two builds after that route was deleted, because the flow
    /// wrote its own copy and had no way to know what the chooser offered.
    @Test("the flow reports what went wrong, not what to do about it")
    func failureCarriesNoUserCopy() async {
        let browser = ScriptedBrowser(.completed(URL(string: "storyteller://settings")!))
        let outcome = await AppTokenSignInFlow(serverURL: server, browser: browser).run()
        #expect(outcome == .failed(.noToken))
    }
}

@Suite("Reading the callback")
struct AppTokenCallbackTests {
    @Test("the scheme is checked, because this is the credential")
    func wrongSchemeIsRefused() {
        #expect(AppTokenGrant.token(from: URL(string: "https://evil.example/?token=abc")!) == nil)
        #expect(AppTokenGrant.token(from: URL(string: "issareader://x?token=abc")!) == nil)
        #expect(AppTokenGrant.token(from: URL(string: "STORYTELLER://settings?token=abc")!) == "abc")
    }

    /// The path is the server's business — it names a screen in its own app —
    /// and this client has no stake in which one.
    @Test("the path is not")
    func anyPathIsAccepted() {
        #expect(AppTokenGrant.token(from: URL(string: "storyteller://settings?token=a")!) == "a")
        #expect(AppTokenGrant.token(from: URL(string: "storyteller://whatever?token=a")!) == "a")
    }

    @Test("an empty or absent token is no token")
    func emptyToken() {
        #expect(AppTokenGrant.token(from: URL(string: "storyteller://settings?token=")!) == nil)
        #expect(AppTokenGrant.token(from: URL(string: "storyteller://settings")!) == nil)
        #expect(AppTokenGrant.token(from: URL(string: "storyteller://settings?other=a")!) == nil)
    }

    @Test("a percent-encoded token is decoded once, not twice")
    func encoding() {
        let url = URL(string: "storyteller://settings?token=a%2Bb%2Fc%3D")!
        #expect(AppTokenGrant.token(from: url) == "a+b/c=")
    }
}
