import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// What must not survive a sign-out.
///
/// Written after the fact, which is the point: the sign-out widening, the
/// position reorder, the catalogue fence and the Mac quit flush all shipped in
/// this session with no coverage at all, and the one that was outright broken —
/// a `@MainActor` deadlock on quit — was found by reasoning rather than by any
/// test. These are the ones reachable without a live server.
///
/// Every sign-out here keeps the downloads. The download directory is the host
/// app's real one — there is no other for `StorageRoot` to name — so a
/// sign-out that deleted them deleted whatever had been downloaded in that
/// simulator, and the files `DownloadRemovalTests` plants there while it runs
/// alongside. None of these assertions is about the files going.
@Suite("Signing out leaves nothing keyed to the account behind")
@MainActor
struct SignOutStateTests {
    /// The server hands the same book uuids to a different reader, which is why
    /// `positionGuards` was already cleared — and why everything else keyed the
    /// same way has to be. `pendingBook` is a book uuid: a widget tap left
    /// unconsumed opened in the *next* account's library.
    @Test("a pending deep link does not survive into the next account")
    func pendingBookIsCleared() async {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        app.requestBook("11111111-1111-4111-8111-111111111111", .read)
        #expect(app.pendingBook != nil, "the link has to be armed for the test to mean anything")

        await app.signOut(keepDownloads: true)
        #expect(app.pendingBook == nil)
    }

    /// Catalogue-derived state. `ratings` is the newest of these — it only
    /// began persisting this session, so a sign-out that left it behind would
    /// now survive a relaunch rather than merely a session.
    ///
    /// Not the downloaded set: that is the disk's answer, not the account's,
    /// and a sign-out that keeps the downloads keeps it (below).
    @Test("the catalogue and everything derived from it is dropped")
    func catalogueStateIsCleared() async {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        app.ratings["11111111-1111-4111-8111-111111111111"] = 4

        await app.signOut(keepDownloads: true)
        #expect(app.books.isEmpty)
        #expect(app.ratings.isEmpty)
        #expect(app.statuses.isEmpty)
        #expect(app.loadError == nil)
    }

    /// Keeping the downloads keeps them on the device and in the set the
    /// shelves are drawn from. The file is planted in the app's real download
    /// directory under a uuid of its own, and is the canary for the rest of
    /// the suite: these sign-outs must leave that directory alone.
    @Test("a sign-out that keeps the downloads leaves them on the device, and listed")
    func keptDownloadsStayOnTheDevice() async throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = UUID().uuidString
        let directory = BookContentService.defaultDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = BookContentService.localURL(in: directory, bookUUID: uuid, format: .ebook)
        try Data(repeating: 0, count: 32).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        await app.signOut(keepDownloads: true)

        #expect(FileManager.default.fileExists(atPath: file.path),
                "a sign-out asked to keep the downloads deleted the app's own")
        #expect(app.downloadedUUIDs.contains(uuid),
                "a download kept on the device was dropped from the shelves")
    }

    /// Per-book reader styles live on `PlaybackSettings`, which `AppModel` does
    /// not own — hence the notification. A test that only checked `AppModel`
    /// would have missed whether the message is actually sent.
    ///
    /// On a centre of this test's own rather than the default one. The message
    /// is process-wide and both its real observers register with `object: nil`,
    /// so posting it here cleared the per-book styles, volume trims and question
    /// indexes of every suite running in parallel. Scoping it costs this test
    /// nothing — the assertion is still that the message is sent.
    @Test("per-book reader styles are told to go too")
    func perBookStylesAreNotified() async {
        let centre = NotificationCenter()
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: centre)
        var received = false
        let token = centre.addObserver(
            forName: PlaybackSettings.signOutNotification, object: nil, queue: .main,
        ) { _ in received = true }
        defer { centre.removeObserver(token) }

        await app.signOut(keepDownloads: true)
        // The observer is delivered on the main queue; we are on it.
        await Task.yield()
        #expect(received, "PlaybackSettings.bookStyles is keyed by book uuid like the rest")
    }
}

/// A token store that never touches the keychain, so these tests neither read
/// nor write the real one.
private final class InMemoryTokens: TokenPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    func read(account: String) -> String? { lock.withLock { stored[account] } }

    @discardableResult
    func write(_ token: String, account: String) -> Bool {
        lock.withLock { stored[account] = token }
        return true
    }

    @discardableResult
    func delete(account: String) -> Bool {
        lock.withLock { _ = stored.removeValue(forKey: account) }
        return true
    }
}
