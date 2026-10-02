import Foundation
import IssaAsk
import IssaCore
import Testing

@testable import IssaReader_iOS

/// Tapping "Your answer is ready" when that book's reader is already up.
///
/// The open reader takes the tap through `reopenRequest` — its handler opens
/// the answer — so a request for the book has nothing left to do. The delegate
/// armed one anyway. The iPhone's root drops a request for the book on screen,
/// but the Mac's library window consumes whatever is waiting as it appears:
/// a tap while only a reader window was open left a request behind, and the
/// next time the library window was shown it opened the book again, unasked.
@Suite("Tapping an answer notification")
@MainActor
struct AskNotificationTapTests {
    private static let bookUUID = "22222222-2222-4222-8222-222222222222"

    private static func delegate(
        centre: NotificationCenter = NotificationCenter(),
    ) -> (AskNotificationDelegate, AskCoordinator, AppModel, String) {
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        let coordinator = AskCoordinator(
            store: AskIndexStore(directory: URL.temporaryDirectory
                .appending(path: "issa-ask-tap-\(UUID().uuidString)")),
            notifier: nil,
            defaults: defaults,
            centre: NotificationCenter(),
        )
        let app = AppModel(keychain: TapNoTokens(), notificationCentre: NotificationCenter())
        return (AskNotificationDelegate(coordinator: coordinator, app: app, centre: centre),
                coordinator, app, suite)
    }

    /// Every `bringReaderForward` posted on one centre, by the book it named.
    @MainActor
    private final class Forwards {
        private(set) var books: [String?] = []
        private var token: (any NSObjectProtocol)?

        init(_ centre: NotificationCenter) {
            // Delivered synchronously on the posting thread, so what the tap
            // posted is here by the time `open` returns — no wait needed.
            token = centre.addObserver(
                forName: AskNotificationDelegate.bringReaderForward, object: nil, queue: nil,
            ) { [weak self] note in
                let book = note.userInfo?[AskNotifier.bookUUIDKey] as? String
                MainActor.assumeIsolated { self?.books.append(book) }
            }
        }

        func stop(_ centre: NotificationCenter) {
            if let token { centre.removeObserver(token) }
        }
    }

    @Test("a tap for the book already being read asks only its reader")
    func readerOnScreenTakesTheTap() {
        let (delegate, coordinator, app, suite) = Self.delegate()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        app.setReaderVisible(Self.bookUUID, true)
        defer { app.setReaderVisible(Self.bookUUID, false) }

        delegate.open(bookUUID: Self.bookUUID)

        #expect(coordinator.reopenRequest == Self.bookUUID, "the reader on screen opens the answer")
        #expect(app.pendingBook == nil,
                "a request left waiting opens the book again when the Mac's library window next appears")
    }

    /// Without the request, nothing brought the Mac's reader window to the
    /// front any more — the request was what reached `openWindow`. The window
    /// is asked for directly instead, by a post that nothing keeps.
    @Test("a tap for the book already being read asks its window to come forward, once")
    func readerOnScreenIsBroughtForward() {
        let centre = NotificationCenter()
        let forwards = Forwards(centre)
        defer { forwards.stop(centre) }
        let (delegate, _, app, suite) = Self.delegate(centre: centre)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        app.setReaderVisible(Self.bookUUID, true)
        defer { app.setReaderVisible(Self.bookUUID, false) }

        delegate.open(bookUUID: Self.bookUUID)

        #expect(forwards.books == [Self.bookUUID])
        #expect(app.pendingBook == nil, "bringing the window forward must not leave a request behind")
    }

    @Test("a tap for a book not on screen goes by the request, not by a forward")
    func otherBookIsNotForwarded() {
        let centre = NotificationCenter()
        let forwards = Forwards(centre)
        defer { forwards.stop(centre) }
        let (delegate, _, app, suite) = Self.delegate(centre: centre)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        app.setReaderVisible("some-other-book", true)
        defer { app.setReaderVisible("some-other-book", false) }

        delegate.open(bookUUID: Self.bookUUID)

        #expect(forwards.books.isEmpty)
        #expect(app.pendingBook?.uuid == Self.bookUUID)
    }

    @Test("a tap for a book not on screen still opens it")
    func otherBookIsRequested() {
        let (delegate, coordinator, app, suite) = Self.delegate()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        app.setReaderVisible("some-other-book", true)
        defer { app.setReaderVisible("some-other-book", false) }

        delegate.open(bookUUID: Self.bookUUID)

        #expect(coordinator.reopenRequest == Self.bookUUID)
        #expect(app.pendingBook == AppModel.PendingBook(uuid: Self.bookUUID, destination: .read))
    }

    @Test("a tap with no reader up opens the book")
    func noReaderRequestsTheBook() {
        let (delegate, _, app, suite) = Self.delegate()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        delegate.open(bookUUID: Self.bookUUID)

        #expect(app.pendingBook == AppModel.PendingBook(uuid: Self.bookUUID, destination: .read))
    }
}

/// A token store that never touches the keychain.
private final class TapNoTokens: TokenPersisting, @unchecked Sendable {
    func read(account: String) -> String? { nil }
    @discardableResult func write(_ token: String, account: String) -> Bool { true }
    @discardableResult func delete(account: String) -> Bool { true }
}
