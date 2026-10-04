import Foundation
import IssaAsk
import IssaCore
import IssaRender
import Testing

@testable import IssaReader_iOS

/// "Sign Out and Delete Downloads" with a book from the reader's files open
/// and narrating. Everything the account owned goes; the book, its narration,
/// its lock screen, its reader, its typography, its level and its question
/// index stay — they are the device's.
///
/// Every object here is the test's own: the app's notification centre, the
/// settings' and the coordinator's, the library's folders, and the storage root
/// the sign-out deletes from (`AppModel.storageRoot`), so the destructive
/// sign-out runs for real without reaching the host app's downloads or any
/// suite running beside this one.
@Suite("Signing out leaves the device's own books alone")
@MainActor
struct LocalAccountIsolationTests {
    @Test("sign-out and delete downloads keeps a narrating local book, and takes the account's")
    func signOutKeepsLocalBooks() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("readalong"))
        let localBook = try #require(local.library.books.first)
        let serverBook = SharedFixtures.book("Dracula", uuid: UUID().uuidString.lowercased())

        // The app, and the objects that hear its sign-out, on one centre.
        let centre = NotificationCenter()
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: centre)
        app.localBookUUIDs = { [library = local.library] in library.uuids }
        // The storage root is the folder `Local/` sits in, as `StorageRoot`
        // is in the app: a root beside the library instead of above it could
        // not see a sign-out that took `Local/` with the account's folders.
        let storage = local.base
        app.storageRoot = storage
        try #require(local.root == storage.appending(path: "Local", directoryHint: .isDirectory))
        let nowPlaying = NowPlayingController()
        app.nowPlayingController = nowPlaying
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        _ = defaults
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite, centre: centre)
        let askDirectory = local.base.appending(path: "Ask", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: askDirectory, withIntermediateDirectories: true)
        let askStore = AskIndexStore(directory: askDirectory)
        let ask = AskCoordinator(
            store: askStore, model: ScriptedAnswerModel(turns: []), notifier: nil,
            defaults: defaults, centre: centre)

        // Per-book state for both books.
        var style = ReaderStyleOverride()
        style.fontSize = 22
        settings.setOverride(style, for: localBook.uuid)
        settings.setOverride(style, for: serverBook.uuid)
        settings.setVolumeTrim(-3, for: localBook.uuid)
        settings.setVolumeTrim(-3, for: serverBook.uuid)
        for uuid in [localBook.uuid, serverBook.uuid] {
            try Data("index".utf8).write(to: askStore.indexURL(for: uuid))
        }
        // The account's downloads, where the sign-out deletes from.
        for folder in ["Books", "Audio", "Fonts/\(serverBook.uuid)"] {
            let url = storage.appending(path: folder, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appending(path: "file"))
        }

        // A server book open, and the local book narrating.
        let session = Session(
            serverURL: URL(string: "https://library.example")!,
            keychain: LocalTestTokens(), session: URLSession(configuration: .ephemeral))
        let serverModel = app.reader(for: serverBook, session: session)
        let localModel = app.reader(for: localBook, persistence: local.library)
        await localModel.open(pageSize: CGSize(width: 340, height: 560))
        try #require(localModel.phase == .ready)
        let readalong = try #require(localModel.readalong)
        readalong.player.play()
        try #require(app.reader === localModel, "the local book has to be the one narrating")
        try #require(nowPlaying.book?.uuid == localBook.uuid)

        await app.signOut(keepDownloads: false, nowPlaying: nowPlaying)
        // The observers are delivered on the main queue; we are on it.
        await Task.yield()

        // Still the device's, and still going.
        #expect(app.reader(for: localBook, persistence: local.library) === localModel,
                "the local reader was released with the account")
        #expect(app.reader === localModel, "its narration was stopped")
        #expect(nowPlaying.book?.uuid == localBook.uuid, "its lock-screen controls were taken away")
        #expect(localModel.readalong?.player.isPlaying == true)
        #expect(local.library.books.map(\.uuid) == [localBook.uuid])
        let files = local.library.files(for: localBook.uuid)
        #expect(FileManager.default.fileExists(atPath: files.epub.path))
        #expect(FileManager.default.fileExists(atPath: files.narration.path))
        #expect(FileManager.default.fileExists(atPath: local.root.path), "Local/ went with the account")
        #expect(FileManager.default.fileExists(atPath: local.storeDirectory.path),
                "the device store went with the account")
        #expect(settings.override(for: localBook.uuid) != nil, "the local book's typography went")
        #expect(settings.volumeTrim(for: localBook.uuid) == -3, "and its level")
        #expect(FileManager.default.fileExists(atPath: askStore.indexURL(for: localBook.uuid).path),
                "and its question index")

        // The account's, gone.
        #expect(app.reader(for: serverBook, session: session) !== serverModel,
                "the account's reader outlived it")
        #expect(settings.override(for: serverBook.uuid) == nil)
        #expect(settings.volumeTrim(for: serverBook.uuid) == 0)
        let indexGone = await LocalImportTests.eventually {
            !FileManager.default.fileExists(atPath: askStore.indexURL(for: serverBook.uuid).path)
        }
        #expect(indexGone, "the account's question index outlived it")
        for folder in ["Books", "Audio", "Fonts/\(serverBook.uuid)"] {
            #expect(!FileManager.default.fileExists(
                atPath: storage.appending(path: folder, directoryHint: .isDirectory).path),
                "\(folder) outlived a sign-out that deletes downloads")
        }

        // And a write the local reader makes afterwards still lands.
        await localModel.saveProgress()
        #expect(local.library.books.first?.position != nil)
        readalong.player.pause()
        app.stopNarration()
        // The coordinator has to be alive to hear the sign-out at all.
        withExtendedLifetime(ask) {}
    }

    /// The other side: with nothing local open or kept, a sign-out still takes
    /// everything it always took.
    @Test("with no local books, sign-out takes every per-book state as before")
    func noLocalBooksNoExemptions() async throws {
        let centre = NotificationCenter()
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: centre)
        let (_, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite, centre: centre)
        settings.setVolumeTrim(-3, for: "11111111-1111-4111-8111-111111111111")

        await app.signOut(keepDownloads: true)
        // Delivered on the main queue; we are on it.
        await Task.yield()

        #expect(settings.bookVolumeTrims.isEmpty)
    }
}
