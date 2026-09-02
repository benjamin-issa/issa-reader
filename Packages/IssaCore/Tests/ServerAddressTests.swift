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
        let http = try #require(URL(string: "http://library.example.com:8001"))
        #expect(ServerAddress.isCleartextFallback(http, forTyped: "library.example.com"))
        #expect(ServerAddress.addressToStore(for: " library.example.com ", connectedTo: http)
            == "library.example.com")
        // What is stored must re-derive the very URL that just answered, or
        // keeping raw text would break the session that stored it…
        #expect(ServerAddress.normalize("library.example.com")?.absoluteString
            == "http://library.example.com:8001")
        // …and the next connect from it must still lead with HTTPS.
        #expect(ServerAddress.candidates(for: "library.example.com").first?.scheme == "https")
        // The downgrade may only ever happen visibly: recording the address
        // is also what writes the warning a diagnostics export shows.
        #expect(IssaLog.export().contains("cleartext HTTP"))
    }

    @Test("an explicit http:// is not treated as a downgrade")
    func explicitHTTPIsNotADowngrade() throws {
        let url = try #require(URL(string: "http://192.168.68.125:8001"))
        #expect(!ServerAddress.isCleartextFallback(url, forTyped: "http://192.168.68.125:8001"))
        #expect(ServerAddress.addressToStore(for: "http://192.168.68.125:8001", connectedTo: url)
            == "http://192.168.68.125:8001")
    }
}
