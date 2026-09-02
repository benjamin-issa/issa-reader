import Foundation
import Testing

@testable import IssaCore

/// The log exists to be handed to somebody else, which is what makes both of
/// these rules load-bearing: it must carry the last six hours, and it must
/// never carry a credential.
@Suite("Diagnostics log")
struct IssaLogTests {
    /// Each file-backed test gets its own directory. The store is a singleton
    /// in the app and a shared file on disk, so tests running in parallel
    /// otherwise read each other's lines.
    func temporaryStore() -> LogStore {
        LogStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("issalog-\(UUID().uuidString)", isDirectory: true))
    }

    /// Goes through the same builder the app writes with. Rebuilding it here
    /// would make every redaction test pass with the redaction deleted.
    func entry(_ message: String, _ fields: [String: String] = [:],
               ago: TimeInterval = 0, level: IssaLog.Level = .info) -> IssaLog.Entry {
        IssaLog.entry(level, message, fields, at: Date() - ago)
    }

    // MARK: - Redaction

    @Test("a bearer token never reaches the file")
    func redactsBearerToken() {
        let line = entry("GET /books failed: Authorization: Bearer eyJhbGciOiJIUzI1.abc-DEF_123").line
        #expect(!line.contains("eyJhbGciOiJIUzI1"))
        #expect(line.contains("«redacted»"))
    }

    @Test("a field named as a secret loses its value whatever it looks like")
    func redactsSecretFields() {
        let line = entry("signing in", ["device_code": "plainlookingvalue", "server": "s.example"]).line
        #expect(!line.contains("plainlookingvalue"))
        #expect(line.contains("server=s.example"), "the useful fields must survive")
    }

    @Test("the short code shown on screen is not recorded")
    func redactsUserCode() {
        #expect(!entry("approve CCXV-LZTD to continue").line.contains("CCXV-LZTD"))
    }

    /// Over-redaction is its own failure. A log that has had the identifiers
    /// scrubbed out of it cannot be matched against anything, and the code
    /// pattern is a shape UUIDs contain.
    @Test("a UUID survives the code pattern")
    func keepsUUIDs() {
        let uuid = "79073E71-3E86-4B2C-A649-E4AB99371125"
        #expect(entry("task \(uuid) failed").line.contains(uuid))
    }

    @Test("a token embedded in a URL query is not recorded")
    func redactsQueryToken() {
        let line = entry("polling https://s.example/token?device_code=UBHO1MuQZWx81snQ").line
        #expect(!line.contains("UBHO1MuQZWx81snQ"))
    }

    /// A reverse proxy with basic auth means the password is *in* the server
    /// address, and the address is logged everywhere a request can fail.
    @Test("credentials typed into the server address are not recorded")
    func redactsURLCredentials() {
        let line = entry("library refresh failed",
                         ["server": "https://ben:hunter2@books.example.com"]).line
        #expect(!line.contains("hunter2"))
        #expect(!line.contains("ben:"))
        #expect(line.contains("books.example.com"), "the host is what makes the report legible")
    }

    /// The same URL rides inside `URLError` descriptions, which no call-site
    /// rule could catch — the scrub has to work on prose.
    @Test("credentials in a URL inside an error description are not recorded")
    func redactsURLCredentialsInProse() {
        let line = entry("Error Domain=NSURLErrorDomain Code=-1004 "
            + "NSErrorFailingURLKey=https://ben:hunter2@books.example.com/api/v2/books").line
        #expect(!line.contains("hunter2"))
        #expect(line.contains("books.example.com/api/v2/books"))
    }

    /// A plain URL must survive the userinfo rule untouched.
    @Test("an address without credentials is kept whole")
    func keepsPlainURLs() {
        let line = entry("connected", ["server": "https://books.example.com/api"]).line
        #expect(line.contains("https://books.example.com/api"))
    }

    /// The other half of the bargain. A log that redacts the server address and
    /// the book title is safe and useless.
    @Test("what makes a report legible is kept")
    func keepsUsefulContext() {
        let line = entry("download failed",
                         ["book": "Peter and Wendy", "server": "storyteller.example.com",
                          "status": "503"]).line
        #expect(line.contains("Peter and Wendy"))
        #expect(line.contains("storyteller.example.com"))
        #expect(line.contains("503"))
    }

    @Test("a secret key is recognised however it is spelled",
          arguments: ["Authorization", "ACCESS_TOKEN", "user-code", "Password"])
    func recognisesSecretKeys(_ key: String) {
        #expect(IssaLog.Redaction.isSecret(key))
    }

    @Test("an ordinary key is not mistaken for a secret",
          arguments: ["server", "book", "status", "site", "chapter"])
    func leavesOrdinaryKeys(_ key: String) {
        #expect(!IssaLog.Redaction.isSecret(key))
    }

    // MARK: - The six-hour window

    @Test("an entry older than six hours is not exported")
    func dropsOldEntries() {
        let store = temporaryStore()
        defer { store.clear() }
        store.append(entry("seven hours ago", ago: 7 * 3600))
        store.append(entry("one hour ago", ago: 3600))
        let text = store.text(since: Date() - IssaLog.window)
        #expect(text.contains("one hour ago"))
        #expect(!text.contains("seven hours ago"))
    }

    @Test("entries come back oldest first, so a report reads forwards")
    func ordersOldestFirst() {
        let store = temporaryStore()
        defer { store.clear() }
        store.append(entry("later", ago: 60))
        store.append(entry("earlier", ago: 3600))
        let lines = store.entries(since: Date() - IssaLog.window).map(\.message)
        #expect(lines == ["earlier", "later"])
    }

    /// The file used to be written with `.iso8601`, which drops fractional
    /// seconds — so two entries milliseconds apart came back simultaneous,
    /// and could come back reordered, in the report that exists to say which
    /// happened first.
    @Test("entries milliseconds apart keep their order through the file")
    func keepsMillisecondOrder() {
        let store = temporaryStore()
        defer { store.clear() }
        let base = Date() - 60
        store.append(IssaLog.entry(.info, "position moved", [:], at: base))
        store.append(IssaLog.entry(.error, "sync mutation failed", [:], at: base + 0.004))
        let entries = store.entries(since: Date() - IssaLog.window)
        #expect(entries.map(\.message) == ["position moved", "sync mutation failed"])
        // Not merely ordered: the times themselves must survive distinct, or
        // the sort above is deciding by luck.
        #expect(entries.count == 2 && entries[0].time < entries[1].time)
    }

    /// The log survives a relaunch — the whole reason it is a file and not
    /// `OSLogStore(scope: .currentProcessIdentifier)`.
    @Test("a second reader of the same files sees what the first wrote")
    func survivesANewStore() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issalog-\(UUID().uuidString)", isDirectory: true)
        let first = LogStore(root: directory)
        defer { first.clear() }
        first.append(entry("written before the crash"))
        first.flush()
        let second = LogStore(root: directory)
        #expect(second.text(since: Date() - IssaLog.window).contains("written before the crash"))
    }

    @Test("an empty log says so rather than exporting nothing")
    func emptyLogIsExplained() {
        let store = temporaryStore()
        defer { store.clear() }
        #expect(store.text(since: Date() - IssaLog.window).contains("No activity"))
    }

    // MARK: - What an error is worth keeping

    @Test("an HTTP failure records its status")
    func describesServerError() {
        let fields = IssaLog.describe(StorytellerError.server(status: 503, message: "down"))
        #expect(fields["status"] == "503")
        #expect(fields["serverMessage"] == "down")
        #expect(fields["retryable"] == "true")
    }

    @Test("a URLError keeps the domain and code that identify it")
    func describesTransportError() {
        let fields = IssaLog.describe(URLError(.notConnectedToInternet))
        #expect(fields["domain"] == NSURLErrorDomain)
        #expect(fields["code"] == "-1009")
    }
}
