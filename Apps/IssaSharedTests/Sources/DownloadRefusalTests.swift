import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// A download the Wi-Fi-only preference holds back is said so, against the
/// edition that was asked for.
///
/// `download(_:format:)` wrote the refusal to `loadError`, the library-load
/// error, and returned false. The book screen's "Save for offline" and "Try
/// again" discard the answer and never read `loadError`; the library shows it
/// only over an empty library; and the Downloads screen hides its "No longer
/// in your library" band and its orphan sweep while it is set. So on cellular
/// the tap did nothing anyone could see, and took two parts of the Downloads
/// screen away until the next successful refresh.
///
/// Through `download`, `downloadsPending`, `downloadAndWait`, `cancelDownload`
/// and `signOut`, with a real `DownloadManager` on a background session of the
/// test's own that never starts a transfer — every download here is refused
/// before it would — and the connection made metered through the model's
/// seam, since nothing else can make a simulator's connection metered.
///
/// `.serialized`: `DownloadManager.wifiOnly` writes the preference into
/// `UserDefaults.standard`, and each test puts it back.
@Suite("A download the Wi-Fi rule refused", .serialized)
@MainActor
struct DownloadRefusalTests {
    static let uuid = "44444444-4444-4444-8444-444444444444"
    static let job = DownloadManager.Job(bookUUID: uuid, format: .readaloud)
    static let wifiOnlyKey = "issa.downloads.wifiOnly"

    struct Fixture {
        let app: AppModel
        let server: URL
        let manager: DownloadManager
        let wifiOnlyWas: Any?

        @MainActor
        func tearDown() {
            manager.stop()
            if let wifiOnlyWas {
                UserDefaults.standard.set(wifiOnlyWas, forKey: DownloadRefusalTests.wifiOnlyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: DownloadRefusalTests.wifiOnlyKey)
            }
            ScriptedServer.forget(server)
        }
    }

    /// Wi-Fi only, on a metered connection, with a book whose read-along
    /// reports no size — which the rule takes for a large one.
    static func fixture() -> Fixture {
        let wifiOnlyWas = UserDefaults.standard.object(forKey: wifiOnlyKey)
        let server = ScriptedServer.make("download-refusal")
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        let session = ScriptedServer.session(on: server, storing: "token-A")
        app.session = session
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "download-refusal-\(UUID().uuidString)", directoryHint: .isDirectory)
        let manager = DownloadManager(
            baseURL: server, tokens: session.tokenProvider,
            identifier: "issa-tests.download-refusal.\(UUID().uuidString)", fenceStore: nil,
        ) { job in scratch.appending(path: "\(job.bookUUID)-\(job.format.rawValue)") }
        manager.wifiOnly = true
        app.useDownloads(manager)
        app.meteredNetworkOverride = true
        app.books = [SharedFixtures.book("Dracula", uuid: uuid, readaloud: true)]
        app.rebuildDerived()
        return Fixture(app: app, server: server, manager: manager, wifiOnlyWas: wifiOnlyWas)
    }

    static var expectedReason: String {
        #if os(macOS)
        "Waiting for an unmetered connection to download this."
        #else
        "Waiting for Wi-Fi to download this."
        #endif
    }

    @Test("a refused download is listed against its edition, and the library error is left alone")
    func aRefusalIsTheJobsNotTheLibrarys() async throws {
        let fixture = Self.fixture()
        defer { fixture.tearDown() }
        let app = fixture.app
        let book = try #require(app.bookByUUID[Self.uuid])

        let started = await app.download(book, format: .readaloud)

        #expect(!started)
        #expect(app.loadError == nil,
                "the refusal went to the library error, hiding half the Downloads screen")
        #expect(app.downloadRefusals[Self.job] == Self.expectedReason)
        let row = app.downloadsPending.first { $0.job == Self.job }
        #expect(row?.state == .failed(Self.expectedReason),
                "the Downloads screen had nothing to show for the tap")
        #expect(fixture.manager.state(for: Self.job) == nil, "and nothing was started")
    }

    /// The reader's own open, which waits for the file, says why it will not
    /// come — the refusal's own sentence, from the job.
    @Test("waiting for a refused download throws the refusal")
    func waitingForARefusedDownloadThrowsTheRefusal() async throws {
        let fixture = Self.fixture()
        defer { fixture.tearDown() }
        let app = fixture.app
        let book = try #require(app.bookByUUID[Self.uuid])

        do {
            _ = try await app.downloadAndWait(book, format: .readaloud) { _, _ in }
            Issue.record("a refused download cannot have arrived")
        } catch let StorytellerError.download(reason) {
            #expect(reason == Self.expectedReason)
        }
        #expect(app.loadError == nil)
    }

    /// The row's X, which is `cancelDownload`, takes a refusal off the list
    /// as it takes a transfer.
    @Test("cancelling a refused download takes its row away")
    func cancellingARefusalClearsIt() async throws {
        let fixture = Self.fixture()
        defer { fixture.tearDown() }
        let app = fixture.app
        let book = try #require(app.bookByUUID[Self.uuid])
        await app.download(book, format: .readaloud)
        try #require(app.downloadRefusals[Self.job] != nil)

        app.cancelDownload(Self.job)

        #expect(app.downloadRefusals.isEmpty)
        #expect(!app.downloadsPending.contains { $0.job == Self.job })
    }

    /// A job is a book uuid and an edition, which the next account on the
    /// server shares; the refusal was said to the reader who asked.
    @Test("a refusal goes with the account")
    func aRefusalGoesWithTheAccount() async throws {
        let fixture = Self.fixture()
        defer { fixture.tearDown() }
        let app = fixture.app
        let book = try #require(app.bookByUUID[Self.uuid])
        await app.download(book, format: .readaloud)
        try #require(app.downloadRefusals[Self.job] != nil)

        await app.signOut(keepDownloads: true)

        #expect(app.downloadRefusals.isEmpty)
        #expect(app.downloadsPending.isEmpty)
    }
}
