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
@Suite("Signing out leaves nothing keyed to the account behind")
@MainActor
struct SignOutStateTests {
    /// The server hands the same book uuids to a different reader, which is why
    /// `positionGuards` was already cleared — and why everything else keyed the
    /// same way has to be. `pendingBook` is a book uuid: a widget tap left
    /// unconsumed opened in the *next* account's library.
    @Test("a pending deep link does not survive into the next account")
    func pendingBookIsCleared() async {
        let app = AppModel(keychain: InMemoryTokens())
        app.requestBook("11111111-1111-4111-8111-111111111111", .read)
        #expect(app.pendingBook != nil, "the link has to be armed for the test to mean anything")

        await app.signOut()
        #expect(app.pendingBook == nil)
    }

    /// Catalogue-derived state. `ratings` is the newest of these — it only
    /// began persisting this session, so a sign-out that left it behind would
    /// now survive a relaunch rather than merely a session.
    @Test("the catalogue and everything derived from it is dropped")
    func catalogueStateIsCleared() async {
        let app = AppModel(keychain: InMemoryTokens())
        app.ratings["11111111-1111-4111-8111-111111111111"] = 4

        await app.signOut()
        #expect(app.books.isEmpty)
        #expect(app.ratings.isEmpty)
        #expect(app.statuses.isEmpty)
        #expect(app.downloadedUUIDs.isEmpty)
        #expect(app.loadError == nil)
    }

    /// Per-book reader styles live on `PlaybackSettings`, which `AppModel` does
    /// not own — hence the notification. A test that only checked `AppModel`
    /// would have missed whether the message is actually sent.
    @Test("per-book reader styles are told to go too")
    func perBookStylesAreNotified() async {
        let app = AppModel(keychain: InMemoryTokens())
        var received = false
        let token = NotificationCenter.default.addObserver(
            forName: PlaybackSettings.signOutNotification, object: nil, queue: .main,
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(token) }

        await app.signOut()
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
