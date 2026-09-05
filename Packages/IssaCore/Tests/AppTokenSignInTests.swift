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

/// Answers the exchange `POST` the way the real server does.
///
/// The status travels in the URL's **port**, so parallel cases share nothing:
/// 200 answers with a session token, anything else refuses. The convention
/// `AppTokenRouteTests` established here, and for the same reason — a `static
/// var` shared between cases is how that suite's first version failed.
private final class ExchangeStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Every body posted through this stub, so a test can assert the wire
    /// format rather than trusting it.
    ///
    /// Appended to rather than overwritten, and asserted with `contains`:
    /// cases run in parallel and share this class, so a "last body" would be
    /// whichever case happened to finish most recently. Each case posts a token
    /// only it uses, which is what makes `contains` an exact assertion.
    nonisolated(unsafe) static var bodies: [Data] = []
    static let bodyLock = NSLock()

    override func startLoading() {
        guard let url = request.url, let status = url.port else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        // `httpBody` is nil for a body set on a request that URLSession has
        // turned into a stream, so read whichever is there.
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        if let body { Self.bodyLock.withLock { Self.bodies.append(body) } }

        let payload = Data(#"{"access_token":"session-token","token_type":"bearer"}"#.utf8)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: status == 200 ? payload : Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExchangeStub.self]
        return URLSession(configuration: configuration)
    }
}

@Suite("Taking a token from the server's own sign-in page")
struct AppTokenSignInTests {
    /// Port 200, so the exchange stub answers with a session token.
    private let server = URL(string: "http://library.example:200")!

    @Test("the browser is pointed at the app-token route")
    func opensTheAppTokenRoute() async {
        let browser = ScriptedBrowser(
            .completed(URL(string: "storyteller://settings?token=abc")!))
        _ = await AppTokenSignInFlow(
            serverURL: server, browser: browser, exchangeSession: ExchangeStub.session()).run()
        #expect(await browser.presented
            == [URL(string: "http://library.example:200/api/v2/token/app")!])
    }

    /// The shape the server actually sends, recorded from a live 2.14.21 on
    /// 2026-09-04: `302 Location: storyteller://settings?token=<JWT>`.
    ///
    /// And what it is *for*, which is the part build 26 got wrong: the callback
    /// carries a five-minute claim ticket, and the session token comes back
    /// from posting it. The flow must hand on the second, never the first.
    @Test("the callback token is traded for a session token, and the session one is returned")
    func takesTheToken() async throws {
        let browser = ScriptedBrowser(
            .completed(URL(string: "storyteller://settings?token=header.payload.signature")!))
        let outcome = await AppTokenSignInFlow(
            serverURL: server, browser: browser, exchangeSession: ExchangeStub.session()).run()
        #expect(outcome == .granted("session-token"))
        #expect(
            outcome != .granted("header.payload.signature"),
            "the claim ticket is not a bearer token and every request with it 401s")

        let bodies = ExchangeStub.bodyLock.withLock { ExchangeStub.bodies }
        let posted = bodies.compactMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        #expect(
            posted.contains(["token": "header.payload.signature"]),
            "the claim ticket goes back in the body, which is where the server reads it")
    }

    /// A server that will not complete the trade is its own failure, with its
    /// own sentence: the reader *did* sign in, and telling them the browser
    /// failed would send them to fix the wrong thing.
    @Test("a refused exchange says so rather than signing nobody in")
    func refusedExchange() async {
        let browser = ScriptedBrowser(
            .completed(URL(string: "storyteller://settings?token=abc")!))
        let outcome = await AppTokenSignInFlow(
            serverURL: URL(string: "http://library.example:401")!,
            browser: browser, exchangeSession: ExchangeStub.session()).run()
        #expect(outcome == .failed(.couldNotExchange(status: 401)))
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
            serverURL: server, browser: ScriptedBrowser(from),
            exchangeSession: ExchangeStub.session()).run()
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
        let flow = AppTokenSignInFlow(
            serverURL: server, browser: browser, exchangeSession: ExchangeStub.session())
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
        let flow = AppTokenSignInFlow(
            serverURL: server, browser: browser, exchangeSession: ExchangeStub.session())
        let task = Task { await flow.run() }
        await browser.waitUntilPresented()
        browser.finish(with: .completed(URL(string: "storyteller://settings?token=late")!))
        #expect(await task.value == .granted("session-token"))
    }

    @Test("a callback with no token says so rather than signing nobody in")
    func callbackWithoutAToken() async {
        let browser = ScriptedBrowser(.completed(URL(string: "storyteller://settings")!))
        let outcome = await AppTokenSignInFlow(
            serverURL: server, browser: browser,
            exchangeSession: ExchangeStub.session()).run()
        guard case let .failed(failure) = outcome else { return #expect(Bool(false)) }
        #expect(failure == .noToken)
    }

    @Test("a browser that will not open carries its reason through")
    func couldNotOpen() async {
        let browser = ScriptedBrowser(.couldNotOpen("Couldn't open your server's sign-in page."))
        let outcome = await AppTokenSignInFlow(
            serverURL: server, browser: browser,
            exchangeSession: ExchangeStub.session()).run()
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
        let outcome = await AppTokenSignInFlow(
            serverURL: server, browser: browser,
            exchangeSession: ExchangeStub.session()).run()
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
