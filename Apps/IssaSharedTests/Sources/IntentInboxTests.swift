import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// "Hey Siri, continue my book", from a cold launch.
///
/// The intent leaves the book in an inbox, and the inbox was collected only
/// when the scene *became* active. A cold launch reaches `.active` before the
/// library exists, so the request sat there until the reader next left the app
/// and came back — when the book opened unasked. The library now collects it
/// as it appears and whenever it is written; this is the collection.
@Suite("Collecting a Siri request")
@MainActor
struct IntentInboxTests {
    @Test("a waiting request is handed to the app once, as a request to read")
    func deliversOnce() {
        let inbox = AppIntentInbox()
        let app = AppModel(keychain: NoTokens(), notificationCentre: NotificationCenter())
        inbox.bookID = "dracula"

        inbox.deliver(to: app)
        #expect(app.pendingBook == AppModel.PendingBook(uuid: "dracula", destination: .read))
        #expect(inbox.bookID == nil, "collected means gone, or the next foreground opens it again")

        app.requestBook("other", .details)
        inbox.deliver(to: app)
        #expect(app.pendingBook?.uuid == "other", "an empty inbox asks for nothing")
    }

    @Test("the inbox is observed, so a request written while the library is up is seen")
    func writesAreObserved() async throws {
        let inbox = AppIntentInbox()
        let seen = Flag()
        withObservationTracking {
            _ = inbox.bookID
        } onChange: {
            seen.set()
        }
        inbox.bookID = "dracula"
        #expect(seen.isSet, "a plain stored property gives `onChange(of:)` nothing to watch")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// A token store that never touches the keychain.
private final class NoTokens: TokenPersisting, @unchecked Sendable {
    func read(account: String) -> String? { nil }
    @discardableResult func write(_ token: String, account: String) -> Bool { true }
    @discardableResult func delete(account: String) -> Bool { true }
}
