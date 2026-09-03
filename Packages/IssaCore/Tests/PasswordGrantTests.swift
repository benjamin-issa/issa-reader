import Foundation
import Testing

@testable import IssaCore

/// Drives the password grant without a network, the way `ScriptedTransport`
/// does for the device grant.
private actor ScriptedPasswordTransport: PasswordGrantTransport {
    private var outcomes: [PasswordGrantOutcome]
    private let declaredSupport: PasswordLoginSupport
    private(set) var attempts = 0
    /// Usernames only. A test fixture that recorded passwords would be the same
    /// mistake this whole file exists to prevent.
    private(set) var namesSeen: [String] = []
    private(set) var passwordLengths: [Int] = []

    init(outcomes: [PasswordGrantOutcome] = [], support: PasswordLoginSupport = .available) {
        self.outcomes = outcomes
        declaredSupport = support
    }

    func signIn(_ credentials: Credentials) async -> PasswordGrantOutcome {
        attempts += 1
        namesSeen.append(credentials.usernameOrEmail)
        passwordLengths.append(credentials.password.count)
        return outcomes.isEmpty ? .rejected : outcomes.removeFirst()
    }

    func probeSupport() async -> PasswordLoginSupport { declaredSupport }
}

@Suite("Signing in with a username and password")
struct PasswordGrantTests {
    @Test("an empty field never reaches the network")
    func emptyFieldsAreRefusedLocally() async throws {
        for credentials in [
            Credentials(usernameOrEmail: "", password: "hunter2"),
            Credentials(usernameOrEmail: "ben", password: ""),
            Credentials(usernameOrEmail: "   \n ", password: "hunter2"),
        ] {
            let transport = ScriptedPasswordTransport(outcomes: [.granted("t")])
            let outcome = await PasswordSignIn(transport: transport).signIn(credentials)
            #expect(outcome == .failed("Enter your username and password."))
            #expect(await transport.attempts == 0)
        }
    }

    @Test("the username is trimmed and the password is not")
    func trimming() async throws {
        let transport = ScriptedPasswordTransport(outcomes: [.granted("t")])
        _ = await PasswordSignIn(transport: transport).signIn(
            Credentials(usernameOrEmail: "  ben\n", password: " hunter2 "))
        #expect(await transport.namesSeen == ["ben"])
        // A trailing space in a password is a character somebody chose.
        #expect(await transport.passwordLengths == [" hunter2 ".count])
    }

    @Test("a rejection is not retried")
    func rejectionIsNotRetried() async throws {
        let transport = ScriptedPasswordTransport(outcomes: [.rejected])
        let outcome = await PasswordSignIn(transport: transport).signIn(
            Credentials(usernameOrEmail: "ben", password: "wrong"))
        #expect(outcome == .rejected)
        #expect(await transport.attempts == 1)
    }
}

@Suite("What the server's answer means")
struct PasswordGrantStatusTests {
    private func outcome(_ status: Int, _ body: String = "") -> PasswordGrantOutcome {
        HTTPPasswordGrantTransport.outcome(status: status, body: Data(body.utf8))
    }

    /// The one that stops someone routing this POST through `APIClient` later:
    /// that client maps 401 to `notAuthenticated`, whose text is "Your session
    /// has ended." A reader who mistyped their password never had a session.
    @Test("a wrong password reads as a wrong password, not as an expired session")
    func wrongPasswordIsNotAnExpiredSession() {
        #expect(outcome(401) == .rejected)
        let text = AppFacingError.text(for: StorytellerError.notAuthenticated)
        #expect(text.contains("session"))
        // …and `.rejected` carries no text at all, so that sentence cannot reach
        // the screen down this path.
        guard case .rejected = outcome(401) else { return #expect(Bool(false)) }
    }

    @Test("a token comes back")
    func tokenIsDecoded() {
        #expect(outcome(200, #"{"access_token":"abc","token_type":"bearer"}"#) == .granted("abc"))
    }

    @Test("a 200 with no token is not silently treated as success")
    func emptySuccessIsAFailure() {
        guard case let .failed(reason) = outcome(200, "{}") else { return #expect(Bool(false)) }
        #expect(reason.contains("token"))
    }

    @Test("the rejected statuses")
    func rejectedStatuses() {
        #expect(outcome(400) == .rejected)
        #expect(outcome(422) == .rejected)
    }

    @Test("a permission failure says so rather than asking for the password again")
    func forbidden() {
        guard case let .failed(reason) = outcome(403) else { return #expect(Bool(false)) }
        #expect(reason == AppFacingError.text(for: StorytellerError.forbidden))
    }

    @Test("an absent route reads as unsupported, not as a wrong password")
    func unsupportedStatuses() {
        for status in [404, 405, 410, 501] {
            #expect(outcome(status) == .unsupported)
        }
    }

    @Test("a redirect is refused out loud")
    func redirect() {
        guard case let .failed(reason) = outcome(302) else { return #expect(Bool(false)) }
        #expect(reason.contains("redirected"))
    }

    @Test("rate limiting says to wait")
    func rateLimited() {
        guard case let .failed(reason) = outcome(429) else { return #expect(Bool(false)) }
        #expect(reason.contains("Wait"))
    }

    @Test("a status nobody anticipated still produces a sentence")
    func unanticipatedStatus() {
        for status in [418, 502, 507] {
            guard case let .failed(reason) = outcome(status) else { return #expect(Bool(false)) }
            #expect(!reason.isEmpty)
            #expect(reason.hasSuffix("."))
            // Never a raw enum dump, which is the rule StorytellerError states.
            #expect(!reason.contains("StorytellerError"))
        }
    }
}

@Suite("Whether this server has a password route at all")
struct PasswordLoginProbeTests {
    /// Recorded against Storyteller 2.14.21 on 2026-09-03. This is the
    /// counter-intuitive one, and it is why the probe is pinned by a test: on a
    /// Next.js route tree a GET to a route that exports only POST answers 405,
    /// while a path with nothing mounted answers 404. Read it the obvious way
    /// round and password sign-in disappears from every server that has it.
    @Test("405 means the password route is there")
    func methodNotAllowedMeansPresent() {
        #expect(HTTPPasswordGrantTransport.support(fromProbeStatus: 405) == .available)
    }

    @Test("404 means it is not")
    func notFoundMeansAbsent() {
        #expect(HTTPPasswordGrantTransport.support(fromProbeStatus: 404) == .unavailable)
        #expect(HTTPPasswordGrantTransport.support(fromProbeStatus: 410) == .unavailable)
    }

    @Test("any other answer about the route counts as present")
    func answeredMeansPresent() {
        for status in [200, 400, 401, 403] {
            #expect(HTTPPasswordGrantTransport.support(fromProbeStatus: status) == .available)
        }
    }

    @Test("no answer, or the server having a bad day, is not an answer")
    func inconclusive() {
        for status in [-1, 500, 502, 503] {
            #expect(HTTPPasswordGrantTransport.support(fromProbeStatus: status) == .unknown)
        }
    }

    /// So a future path split cannot silently probe one route and post to another.
    @Test("the probed path is the one the sign-in posts to")
    func probeAndPostAgree() {
        #expect(Endpoint.token == "/api/v2/token")
        #expect(Endpoint.validate == "/api/v2/validate")
    }
}

@Suite("Encoding the form")
struct PasswordFormEncodingTests {
    private func encoded(_ fields: [(String, String)]) -> String {
        String(decoding: HTTPPasswordGrantTransport.formEncoded(fields), as: UTF8.self)
    }

    @Test("the field names are the server's, exactly")
    func fieldNames() {
        let body = encoded([("usernameOrEmail", "ben"), ("password", "pw")])
        #expect(body == "usernameOrEmail=ben&password=pw")
    }

    /// The bug this encoder exists to avoid: a password that works in a browser
    /// and fails in the app, with nothing on either side to say why.
    @Test("a password containing + or & survives")
    func reservedCharacters() {
        let password = "a+b&c=d%e f"
        let body = encoded([("password", password)])
        let value = String(body.dropFirst("password=".count))
        #expect(!value.contains("+"))
        #expect(!value.contains("&"))
        #expect(!value.contains("="))
        #expect(!value.contains(" "))
        #expect(value.removingPercentEncoding == password)
    }

    @Test("a space is %20, never +")
    func spaceEncoding() {
        #expect(encoded([("password", "two words")]) == "password=two%20words")
    }

    @Test("non-ASCII round-trips")
    func unicode() {
        let body = encoded([("usernameOrEmail", "bénjamin")])
        #expect(body == "usernameOrEmail=b%C3%A9njamin")
        #expect(String(body.dropFirst("usernameOrEmail=".count)).removingPercentEncoding == "bénjamin")
    }
}

@Suite("Credentials cannot leak by accident")
struct CredentialsRedactionTests {
    @Test("printing them prints nothing")
    func printing() {
        let credentials = Credentials(usernameOrEmail: "ben", password: "hunter2")
        #expect(!String(describing: credentials).contains("hunter2"))
        #expect(!String(describing: credentials).contains("ben"))
        #expect(!String(reflecting: credentials).contains("hunter2"))
        #expect(!"\(credentials)".contains("hunter2"))
    }
}
