import Foundation
import Testing

@testable import IssaCore

/// The first thing every reader types, and the easiest thing to get wrong in a
/// way that looks like the server is down.
@Suite("Reading a server address")
struct ServerAddressTests {
    // MARK: - What one address means

    @Test("a bare host takes Storyteller's own default port")
    func bareHostGetsDefaultPort() throws {
        let url = try #require(ServerAddress.normalize("storyteller.home.arpa"))
        #expect(url.absoluteString == "http://storyteller.home.arpa:8001")
    }

    @Test("a full URL is taken at its word, port and all")
    func fullURLIsNotSecondGuessed() throws {
        #expect(try #require(ServerAddress.normalize("https://books.example.com")).absoluteString
            == "https://books.example.com")
        #expect(try #require(ServerAddress.normalize("http://10.0.0.4:9999")).absoluteString
            == "http://10.0.0.4:9999")
    }

    /// A reverse proxy commonly mounts Storyteller under a subdirectory.
    @Test("a subdirectory survives; a pasted API path and trailing slash do not")
    func pathIsKeptButTidied() throws {
        #expect(try #require(ServerAddress.normalize("https://example.com/books/")).absoluteString
            == "https://example.com/books")
        #expect(try #require(ServerAddress.normalize("https://example.com/books/api/v2")).absoluteString
            == "https://example.com/books")
    }

    @Test("nonsense is refused rather than guessed at")
    func rejectsNonsense() {
        #expect(ServerAddress.normalize("") == nil)
        #expect(ServerAddress.normalize("   ") == nil)
        #expect(ServerAddress.normalize("http://") == nil)
    }

    // MARK: - What to try

    /// The bug this exists for: a proxied server answers on 443, and guessing
    /// 8001 connects to a port with nothing on it — which hangs rather than
    /// refusing, so the app sat on "Contacting your server…" indefinitely.
    @Test("a bare host tries HTTPS before Storyteller's raw port")
    func bareHostTriesHTTPSFirst() {
        let candidates = ServerAddress.candidates(for: "storyteller.example.com")
        #expect(candidates.map(\.absoluteString) == [
            "https://storyteller.example.com",
            "http://storyteller.example.com:8001",
        ])
    }

    /// Someone who typed a scheme has said what they meant, and a deliberate
    /// http:// on a LAN must not be silently upgraded.
    @Test("an explicit scheme is the only thing tried")
    func explicitSchemeIsNotExpanded() {
        #expect(ServerAddress.candidates(for: "http://storyteller.home.arpa:8001")
            .map(\.absoluteString) == ["http://storyteller.home.arpa:8001"])
        #expect(ServerAddress.candidates(for: "https://books.example.com")
            .map(\.absoluteString) == ["https://books.example.com"])
    }

    @Test("an address that means one thing is not tried twice")
    func noDuplicates() {
        #expect(ServerAddress.candidates(for: "example.com").count == 2)
        #expect(Set(ServerAddress.candidates(for: "example.com")).count == 2)
    }

    @Test("nothing typed is nothing to try")
    func emptyIsEmpty() {
        #expect(ServerAddress.candidates(for: "  ").isEmpty)
    }

    // MARK: - What to remember

    /// The three sides of the cleartext bargain. A bare host that answered
    /// over HTTPS remembers the resolved URL; one that fell back to plain
    /// HTTP remembers what was typed, so the next connect tries HTTPS again
    /// rather than making the downgrade permanent; an explicit `http://` is
    /// honoured untouched, because a LAN install depends on it.
    @Test("a bare host that answered over HTTPS remembers the resolved URL")
    func httpsAnswerIsStoredResolved() throws {
        let https = try #require(URL(string: "https://books.example.com"))
        #expect(!ServerAddress.isCleartextFallback(https, forTyped: "books.example.com"))
        #expect(ServerAddress.addressToStore(for: "books.example.com", connectedTo: https)
            == "https://books.example.com")
    }

    @Test("a cleartext fallback remembers what was typed, so HTTPS is retried")
    func cleartextFallbackKeepsTypedText() throws {
        // A host of this run's own. The log store is the real one and keeps
        // six hours, so a fixed phrase was matched by the line any earlier
        // run had written, and this passed with the warning deleted.
        let host = "library-\(UUID().uuidString.lowercased()).example.com"
        let http = try #require(URL(string: "http://\(host):8001"))
        #expect(ServerAddress.isCleartextFallback(http, forTyped: host))
        #expect(ServerAddress.addressToStore(for: " \(host) ", connectedTo: http) == host)
        // What is stored must re-derive the very URL that just answered, or
        // keeping raw text would break the session that stored it…
        #expect(ServerAddress.normalize(host)?.absoluteString == "http://\(host):8001")
        // …and the next connect from it must still lead with HTTPS.
        #expect(ServerAddress.candidates(for: host).first?.scheme == "https")
        // The downgrade may only ever happen visibly: recording the address
        // is also what writes the warning a diagnostics export shows — this
        // one, for this host.
        let warned = IssaLog.export().split(separator: "\n").contains {
            $0.contains("cleartext HTTP") && $0.contains(host)
        }
        #expect(warned, "the downgrade to \(host) left no warning in the log")
    }

    @Test("a cleartext fallback does not remember a typed password")
    func cleartextFallbackDropsUserinfo() throws {
        let host = "library-\(UUID().uuidString.lowercased()).example.com"
        let http = try #require(URL(string: "http://\(host):8001"))
        for typed in ["ben:hunter2@\(host)", "ben@\(host)?token=abc", "ben:hunter2@\(host)#top", "ben:hunter2@\(host)/shelf"] {
            let stored = ServerAddress.addressToStore(for: typed, connectedTo: http)
            #expect(!stored.contains("ben"), "\(typed) stored as \(stored)")
            #expect(!stored.contains("hunter2") && !stored.contains("token") && !stored.contains("top"))
            #expect(stored.hasPrefix(host))
            // Still a bare address, so the next connect leads with HTTPS…
            #expect(ServerAddress.candidates(for: stored).first?.scheme == "https")
        }
        // …and what is stored derives the URL that answered, path and all.
        let stored = ServerAddress.addressToStore(for: "ben:hunter2@\(host)/shelf", connectedTo: http)
        #expect(stored == "\(host)/shelf")
        #expect(ServerAddress.normalize(stored)?.absoluteString == "http://\(host):8001/shelf")
    }

    @Test("an explicit http:// is not treated as a downgrade")
    func explicitHTTPIsNotADowngrade() throws {
        let url = try #require(URL(string: "http://192.168.1.10:8001"))
        #expect(!ServerAddress.isCleartextFallback(url, forTyped: "http://192.168.1.10:8001"))
        #expect(ServerAddress.addressToStore(for: "http://192.168.1.10:8001", connectedTo: url)
            == "http://192.168.1.10:8001")
    }
}

/// The device an earlier build locked out: `https://host` stored over a bare
/// host whose server is plain HTTP on :8001, with the sign-in filed under
/// `http://host:8001`. The HTTP address is offered only when every one of six
/// conditions holds, and is never taken without the reader.
@Suite("Offering a saved sign-in over plain HTTP")
struct CleartextRescueTests {
    static let https = URL(string: "https://library.example")!
    static let http = URL(string: "http://library.example:8001")!

    /// Token storage the test fills, and that says nothing was written.
    final class Tokens: TokenPersisting, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: String]
        private(set) var writes = 0
        private(set) var deletes = 0

        init(_ stored: [String: String]) { self.stored = stored }
        func read(account: String) -> String? { lock.withLock { stored[account] } }
        func write(_ token: String, account: String) -> Bool {
            lock.withLock { writes += 1; stored[account] = token }
            return true
        }

        func delete(account: String) -> Bool {
            lock.withLock { deletes += 1; stored[account] = nil }
            return true
        }
    }

    /// A probe that answers from a script, and records what it was asked.
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private let answers: [URL: ServerProbe]
        private(set) var asked: [URL] = []

        init(https: ServerProbe = .noResponse, http: ServerProbe = .answered(status: 404)) {
            answers = [CleartextRescueTests.https: https, CleartextRescueTests.http: http]
        }

        var probe: @Sendable (URL) async -> ServerProbe {
            { [self] url in
                lock.withLock {
                    asked.append(url)
                    return answers[url] ?? .noResponse
                }
            }
        }
    }

    /// The locked-out device: nothing under HTTPS, the sign-in under HTTP.
    private static func lockedOut() -> Tokens { Tokens([http.absoluteString: "token"]) }

    private func offer(
        connecting address: String = CleartextRescueTests.https.absoluteString,
        stored: String = CleartextRescueTests.https.absoluteString,
        keychain: Tokens = CleartextRescueTests.lockedOut(), probe: Probe = Probe(),
    ) async -> CleartextRescue? {
        await CleartextRescue.offer(connecting: address, stored: stored, keychain: keychain, probe: probe.probe)
    }

    @Test("every condition holding offers the HTTP address, and touches nothing")
    func offered() async {
        let keychain = Self.lockedOut()
        let probe = Probe()
        let offer = await offer(keychain: keychain, probe: probe)
        #expect(offer == CleartextRescue(tried: Self.https, offered: Self.http, bare: "library.example"))
        #expect(probe.asked == [Self.https, Self.http], "HTTPS is asked first, then HTTP")
        #expect(keychain.writes == 0 && keychain.deletes == 0)
        #expect(keychain.read(account: Self.http.absoluteString) == "token")
    }

    @Test("G1: an address just typed is never offered a downgrade")
    func typedAddressIsNotOffered() async {
        let probe = Probe()
        #expect(await offer(stored: "https://elsewhere.example", probe: probe) == nil)
        #expect(probe.asked.isEmpty, "a probe was sent for an address that was not the stored one")
    }

    @Test("G2: a bare address, or an http:// one, is not the locked-out shape")
    func onlyALoneHTTPSAddress() async {
        for address in ["library.example", "http://library.example:8001"] {
            let probe = Probe()
            #expect(await offer(connecting: address, stored: address, probe: probe) == nil, "\(address)")
            #expect(probe.asked.isEmpty, "\(address) was probed")
        }
    }

    @Test("G3: a sign-in saved under the https address means nothing is locked out")
    func httpsSignInEndsIt() async {
        let probe = Probe()
        let keychain = Tokens([Self.https.absoluteString: "a", Self.http.absoluteString: "b"])
        #expect(await offer(keychain: keychain, probe: probe) == nil)
        #expect(probe.asked.isEmpty, "a healthy device paid for a probe")
    }

    @Test("G4: no sign-in under the HTTP address leaves nothing to offer")
    func noHTTPSignInEndsIt() async {
        let probe = Probe()
        let keychain = Tokens(["http://other.example:8001": "b"])
        #expect(await offer(keychain: keychain, probe: probe) == nil)
        #expect(probe.asked.isEmpty)
    }

    @Test("G5: an https address that answers anything, a 503 included, is never given up")
    func httpsAnsweringEndsIt() async {
        for status in [200, 401, 404, 503] {
            let probe = Probe(https: .answered(status: status))
            #expect(await offer(probe: probe) == nil, "HTTPS answered \(status) and was given up")
            #expect(probe.asked == [Self.https], "HTTP was probed after HTTPS answered \(status)")
        }
    }

    @Test("G6: an HTTP address that does not answer is not offered")
    func httpSilentEndsIt() async {
        #expect(await offer(probe: Probe(http: .noResponse)) == nil)
        #expect(await offer(probe: Probe(http: .answered(status: 502))) == nil)
    }

    @Test("the HTTP address keeps a port and path the https one named")
    func counterpartKeepsPortAndPath() throws {
        #expect(ServerAddress.cleartextCounterpart(of: Self.https) == Self.http)
        #expect(ServerAddress.cleartextCounterpart(of: try #require(URL(string: "https://host.example:8443/books")))
            == URL(string: "http://host.example:8443/books"))
        #expect(ServerAddress.cleartextCounterpart(of: Self.http) == nil)
        #expect(ServerAddress.bare(try #require(URL(string: "https://host.example:8443/books")))
            == "host.example:8443/books")
    }

    @Test("what is stored once the offer is taken still leads with HTTPS")
    func storedAddressLeadsWithHTTPS() {
        let offer = CleartextRescue(tried: Self.https, offered: Self.http, bare: "library.example")
        let stored = ServerAddress.addressToStore(for: offer.bare, connectedTo: offer.offered)
        #expect(stored == "library.example")
        #expect(ServerAddress.candidates(for: stored) == [Self.https, Self.http])
    }

    @Test("the offer names both addresses and says the second is not encrypted")
    func wording() {
        let offer = CleartextRescue(tried: Self.https, offered: Self.http, bare: "library.example")
        #expect(offer.message(device: "iPhone")
            == "Couldn't reach https://library.example. This iPhone has a saved sign-in for http://library.example:8001, which is not encrypted.")
        #expect(offer.buttonTitle == "Use http://library.example:8001 (not encrypted)")
    }

    @Test("a probe's answer is a server only from 200 to 499, as it always was")
    func probeReachability() {
        #expect(ServerProbe.answered(status: 200).isReachable)
        #expect(ServerProbe.answered(status: 499).isReachable)
        #expect(!ServerProbe.answered(status: 500).isReachable)
        #expect(!ServerProbe.noResponse.isReachable)
    }
}

@Suite("Credentials in a typed address do not survive normalisation")
struct ServerAddressUserinfoTests {
    /// A reader behind HTTP basic auth types the whole thing. It used to reach
    /// plaintext UserDefaults, a keychain account attribute and the Settings
    /// screen — while IssaLog.Redaction had a rule for exactly this shape, so
    /// the log was the only sink that was protected.
    @Test("userinfo is stripped the way the query and fragment already were")
    func stripsUserinfo() throws {
        let url = try #require(ServerAddress.normalize("https://ben:hunter2@library.home.arpa"))
        #expect(url.user == nil)
        #expect(url.password == nil)
        #expect(!url.absoluteString.contains("hunter2"))
        #expect(!url.absoluteString.contains("ben"))
        #expect(url.host == "library.home.arpa", "the server itself is still reachable")
    }

    @Test("an address with no credentials is untouched")
    func leavesOrdinaryAddressesAlone() throws {
        let url = try #require(ServerAddress.normalize("https://library.home.arpa/books"))
        #expect(url.absoluteString == "https://library.home.arpa/books")
    }
}
