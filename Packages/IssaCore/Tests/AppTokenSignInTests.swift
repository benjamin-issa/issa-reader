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
        guard case let .failed(reason) = outcome else { return #expect(Bool(false)) }
        #expect(reason.contains("token"))
    }

    @Test("a browser that will not open falls out to a sentence")
    func couldNotOpen() async {
        let browser = ScriptedBrowser(.couldNotOpen("Couldn't open your server's sign-in page."))
        let outcome = await AppTokenSignInFlow(serverURL: server, browser: browser).run()
        guard case let .failed(reason) = outcome else { return #expect(Bool(false)) }
        #expect(reason.contains("Couldn't open"))
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

@Suite("What a server says it accepts")
struct ServerAuthMethodsTests {
    /// Recorded from a live 2.14.21 on 2026-09-04. Keyed by provider id, and
    /// `credentials` is how password login appears.
    private let live = Data("""
        {"credentials":{"id":"credentials","name":"Credentials","type":"credentials",
          "signinUrl":"http://x/api/v2/auth/signin/credentials",
          "callbackUrl":"http://x/api/v2/auth/callback/credentials"},
         "keycloak":{"id":"keycloak","name":"Keycloak","type":"oidc",
          "signinUrl":"http://x/api/v2/auth/signin/keycloak",
          "callbackUrl":"http://x/api/v2/auth/callback/keycloak"}}
        """.utf8)

    @Test("password login and the providers are read apart")
    func decodesTheLiveShape() throws {
        let methods = try #require(ServerAuthMethods.decode(live))
        #expect(methods.password)
        #expect(methods.identityProviders.map(\.name) == ["Keycloak"])
        #expect(methods.identityProviders.allSatisfy { !$0.isPassword })
        #expect(!methods.isUnknown)
    }

    @Test("a server with no password route says so")
    func oidcOnly() throws {
        let data = Data(#"{"keycloak":{"id":"keycloak","name":"Keycloak","type":"oidc"}}"#.utf8)
        let methods = try #require(ServerAuthMethods.decode(data))
        #expect(!methods.password)
        #expect(methods.identityProviders.count == 1)
    }

    @Test("nonsense is not mistaken for an answer")
    func garbage() {
        #expect(ServerAuthMethods.decode(Data("not json".utf8)) == nil)
    }

    /// Unknown must offer everything: hiding a route because a proxy answered
    /// oddly is worse than offering one that then says no.
    @Test("unknown fails open")
    func unknownFailsOpen() {
        #expect(ServerAuthMethods.unknown.password)
        #expect(ServerAuthMethods.unknown.isUnknown)
    }
}
