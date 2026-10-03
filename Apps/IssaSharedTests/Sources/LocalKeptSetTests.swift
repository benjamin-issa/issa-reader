import Foundation
import IssaAsk
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// An account's exit keeps the device's own books' per-book state even when
/// it runs before the local library has finished loading.
///
/// The kept set came from `LocalLibrary.books`, which `load()` fills after a
/// store read of its own. An exit before that — a launch hand-over, say —
/// posted an empty set, and the observers took it at its word: every local
/// book's reader style and volume trim went, and the question index store,
/// given nothing to keep, deleted its whole directory, local books' indexes
/// included.
///
/// Through `AppModel.signOut`, with the books' folders under the storage root
/// the model is given (`AppModel.storageRoot`), and the broadcast caught on a
/// centre of the test's own.
@Suite("The kept set before the local library has loaded")
@MainActor
struct LocalKeptSetTests {
    final class Kept: @unchecked Sendable {
        private let lock = NSLock()
        private var sets: [Set<String>] = []
        private var token: (any NSObjectProtocol)?
        let centre = NotificationCenter()

        @MainActor
        init() {
            let key = PlaybackSettings.keptBookUUIDsKey
            token = centre.addObserver(
                forName: PlaybackSettings.signOutNotification, object: nil, queue: nil,
            ) { [weak self] note in
                let kept = note.userInfo?[key] as? Set<String> ?? []
                self?.lock.withLock { self?.sets.append(kept) }
            }
        }

        var received: [Set<String>] { lock.withLock { sets } }
    }

    @Test("an exit before the local library has loaded keeps the books on the disk")
    func anExitBeforeTheLoadKeepsTheDisksBooks() async throws {
        let kept = Kept()
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: kept.centre)
        app.currentBookPublisher = CurrentBookPublisher()
        let storage = FileManager.default.temporaryDirectory
            .appending(path: "kept-set-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: storage) }
        app.storageRoot = storage
        // A book the reader added, on the disk where `LocalLibrary` keeps it,
        // and a library that has not read its store yet.
        let local = UUID().uuidString.lowercased()
        let files = LocalBookFiles(bookUUID: local, root: storage.appending(path: "Local", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: files.folder, withIntermediateDirectories: true)
        try Data("epub".utf8).write(to: files.epub)
        // And the half-finished import `load()` sweeps, which is no book.
        try FileManager.default.createDirectory(
            at: LocalBookFiles.incoming(in: storage.appending(path: "Local", directoryHint: .isDirectory)),
            withIntermediateDirectories: true)
        app.localBookUUIDs = { [] }

        await app.signOut(keepDownloads: true)

        let sets = kept.received
        try #require(sets.count == 1, "the exit has to have told the observers")
        #expect(sets[0].contains(local),
                "a book on the device was purged because the library had not loaded yet")
        #expect(!sets[0].contains(".incoming"))
    }

    /// A book a backup restored without its file is a row in the library's
    /// store and nothing on the disk, so the folders above do not name it:
    /// until `load()` has read the row, nothing did. Wired as both apps'
    /// services wire it (`LocalBooksWiring`), and left the exit straight
    /// after — the launch's load not yet run.
    @Test("an exit before the local library has loaded keeps a book whose file is missing")
    func anExitBeforeTheLoadKeepsABookWithoutItsFile() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let url = try local.pick("readalong")
        await local.importAndWait(url)
        let book = try #require(local.library.books.first)
        // The backup brought back the store and not the copy.
        try FileManager.default.removeItem(at: local.library.files(for: book.uuid).folder)
        let relaunched = local.relaunched()
        defer { relaunched.cancelAllImports() }

        let kept = Kept()
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: kept.centre)
        app.currentBookPublisher = CurrentBookPublisher()
        app.storageRoot = local.base
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let ask = AskCoordinator(
            store: AskIndexStore(directory: local.base.appending(path: "Ask", directoryHint: .isDirectory)),
            notifier: nil, defaults: defaults, centre: NotificationCenter())
        let settings = PlaybackSettings(suiteName: suite, centre: kept.centre)
        LocalBooksWiring.connect(app: app, local: relaunched, ask: ask, settings: settings)
        try #require(!relaunched.isLoaded, "the exit has to overtake the launch's load")

        await app.signOut(keepDownloads: true)

        let sets = kept.received
        try #require(sets.count == 1, "the exit has to have told the observers")
        #expect(sets[0].contains(book.uuid),
                "a book restored without its file was purged because the library had not loaded yet")
    }
}
