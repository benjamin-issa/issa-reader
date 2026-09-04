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

    @Test("closing the window is not an error")
    func dismissal() async {
        for dismissal in [BrowserDismissal.byUser, .byApp] {
            let outcome = await AppTokenSignInFlow(
                serverURL: server, browser: ScriptedBrowser(dismissal)).run()
            #expect(outcome == .dismissed)
        }
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
