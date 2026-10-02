import Foundation
import IssaAsk
import IssaCore
import Testing

@testable import IssaReader_iOS

/// The joins between the local library and the rest of the app: what the
/// app's own services hand over at launch, and where an answer's notification
/// for a local book takes the reader.
@Suite("Books from the reader's files, wired into the app")
@MainActor
struct LocalBooksWiringTests {
    private static let uuid = "33333333-3333-4333-8333-333333333333"

    /// The host app ran `AppServices.start()` as it launched, which is the one
    /// place these are set. Without them an account's exit would take the
    /// device's books' state, a removed book's reader would play on, and its
    /// index, style and level would outlive it.
    @Test("the app's services hand the local library to the app at launch")
    func servicesWireTheLibrary() {
        let services = AppServices.shared
        services.start()
        #expect(services.local.onRemove != nil, "a removed book's reader would be left playing")
        #expect(services.local.onForget != nil, "a removed book's index, style and level would stay")
        #expect(services.app.localBookUUIDs() == services.local.uuids,
                "an account's exit would not know which books are the device's")
    }

    private static func delegate(
        centre: NotificationCenter, local: Set<String>,
    ) -> (AskNotificationDelegate, AppModel, String) {
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        let coordinator = AskCoordinator(
            store: AskIndexStore(directory: URL.temporaryDirectory
                .appending(path: "issa-local-tap-\(UUID().uuidString)")),
            notifier: nil, defaults: defaults, centre: NotificationCenter())
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        app.localBookUUIDs = { local }
        return (AskNotificationDelegate(coordinator: coordinator, app: app, centre: centre), app, suite)
    }

    /// Names posted on a centre, in order, with the book each named.
    @MainActor
    private final class Posts {
        private(set) var seen: [(Notification.Name, String?)] = []
        private var tokens: [any NSObjectProtocol] = []

        init(_ centre: NotificationCenter) {
            for name in [AskNotificationDelegate.openLocalBook, AskNotificationDelegate.bringReaderForward] {
                tokens.append(centre.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                    let book = note.userInfo?[AskNotifier.bookUUIDKey] as? String
                    MainActor.assumeIsolated { self?.seen.append((name, book)) }
                })
            }
        }

        func stop(_ centre: NotificationCenter) { tokens.forEach(centre.removeObserver) }
    }

    /// A request for a book that is not in the server's catalogue waits for it
    /// for ever; a local book is opened where local books open.
    @Test("an answer tapped for a local book opens its reader, not a request for it")
    func tapOpensTheLocalReader() {
        let centre = NotificationCenter()
        let posts = Posts(centre)
        defer { posts.stop(centre) }
        let (delegate, app, suite) = Self.delegate(centre: centre, local: [Self.uuid])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        delegate.open(bookUUID: Self.uuid)

        #expect(app.pendingBook == nil, "a local book was asked of the server's library")
        #expect(posts.seen.map(\.0) == [AskNotificationDelegate.openLocalBook])
        #expect(posts.seen.first?.1 == Self.uuid)
    }

    @Test("an answer tapped for the local book on screen brings its window forward")
    func tapOnScreenBringsItForward() {
        let centre = NotificationCenter()
        let posts = Posts(centre)
        defer { posts.stop(centre) }
        let (delegate, app, suite) = Self.delegate(centre: centre, local: [Self.uuid])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        app.setReaderVisible(Self.uuid, true)
        defer { app.setReaderVisible(Self.uuid, false) }

        delegate.open(bookUUID: Self.uuid)

        #expect(posts.seen.map(\.0) == [AskNotificationDelegate.bringReaderForward])
        #expect(app.pendingBook == nil)
    }

    /// The route the root presents the reader by: remembered across launches,
    /// and opening by uuid.
    @Test("the list's place as the root is remembered, and a book opens by uuid")
    func routeRemembers() {
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let route = LocalBooksRoute(defaults: defaults)
        #expect(!route.showsListSignedOut)
        route.showsListSignedOut = true
        #expect(LocalBooksRoute(defaults: defaults).showsListSignedOut)
        route.open(Self.uuid)
        #expect(route.openBook?.uuid == Self.uuid)
    }
}
