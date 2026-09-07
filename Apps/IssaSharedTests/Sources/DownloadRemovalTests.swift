import Foundation
import IssaAsk
import IssaUI
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// What a removal takes with it, and — more importantly — what it must not.
///
/// A download leaves four kinds of derived file behind: the book itself, the
/// narration extracted from a read-along, the question index built from its
/// text, and the publisher face pulled out of the EPUB. Three of those were
/// being forgotten in at least one path, and the fourth — the reader's own
/// imported fonts, and their annotations — must survive every one of them.
///
/// `.serialized`, because these tests write into the app's real download
/// directory. That is deliberate: `refreshDownloadedSet` reads that directory
/// and nothing else, so a test that pointed it somewhere else would be testing
/// a seam rather than the behaviour. Each test uses a uuid of its own and
/// cleans up after itself.
@Suite("Removing a download", .serialized)
@MainActor
struct DownloadRemovalTests {
    private final class BundleMarker {}

    /// A bare uuid, so `BookContentService` names the file rather than hashing
    /// it — a hashed name does not decode back and the set would never contain
    /// the book at all.
    private static func freshUUID() -> String { UUID().uuidString }

    private static func booksDirectory() throws -> URL {
        let directory = BookContentService.defaultDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private static func plant(
        _ uuid: String, format: BookContentService.Format, bytes: Int = 32,
    ) throws -> URL {
        let url = BookContentService.localURL(
            in: try booksDirectory(), bookUUID: uuid, format: format)
        try Data(repeating: 0, count: bytes).write(to: url)
        return url
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// `AskCoordinator.remove` hands the deletion to the store's actor and the
    /// font sweep is synchronous, so an assertion about the index has to wait
    /// for the hop rather than for the call to return.
    private static func eventually(
        _ condition: @escaping @Sendable () async -> Bool,
    ) async -> Bool {
        for _ in 0 ..< 200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    // MARK: - One edition, not the book

    /// The book screen removes a single edition, and the model refreshes a set
    /// keyed by book uuid — so "does removing the ebook take the read-along
    /// with it" is a question the shape of the state cannot answer on its own.
    @Test("removing one edition leaves the other on the device")
    func removingOneEditionLeavesTheOther() throws {
        let app = AppModel(keychain: InMemoryTokens())
        let uuid = Self.freshUUID()
        let ebook = try Self.plant(uuid, format: .ebook)
        let readaloud = try Self.plant(uuid, format: .readaloud, bytes: 64)
        defer { for url in [ebook, readaloud] { try? FileManager.default.removeItem(at: url) } }

        let book = SharedFixtures.book("Dracula", uuid: uuid, readaloud: true)
        app.refreshDownloadedSet()
        #expect(app.downloadedUUIDs.contains(uuid))

        app.removeDownload(book, format: .ebook)

        #expect(!Self.exists(ebook))
        #expect(Self.exists(readaloud), "the reader asked for one edition to go, not the book")
        #expect(app.downloadedUUIDs.contains(uuid), "the book is still downloaded")
    }

    /// Everything a removal has no business touching. The rating is the newest
    /// of these — it only began persisting recently — and the position is what
    /// a reader would notice first.
    @Test("a removal leaves the rating, the position and the annotations alone")
    func removalLeavesTheReadersOwnDataAlone() async throws {
        let app = AppModel(keychain: InMemoryTokens())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }

        let book = SharedFixtures.book(
            "Dracula", uuid: uuid, status: "Reading", progress: 0.42, positionTimestamp: 99)
        app.books = [book]
        app.ratings[uuid] = 4

        // A real annotation in a real store, because "device-local and this is
        // their only copy" is the whole reason it must survive.
        let serverKey = "removal-test-\(UUID().uuidString)"
        let store = try LibraryStore(serverKey: serverKey)
        defer {
            let file = LibraryStore.defaultDirectory()
                .appending(path: "library-\(LibraryStore.filename(for: serverKey)).sqlite")
            try? FileManager.default.removeItem(at: file)
        }
        try await store.save(Annotation(
            bookUUID: uuid, kind: .highlight,
            locator: ReadiumLocator(href: "OEBPS/ch01.xhtml", type: "application/xhtml+xml"),
            excerpt: "Listen to them, the children of the night.",
        ))

        app.removeDownload(book, format: .ebook)

        #expect(!Self.exists(file))
        #expect(app.ratings[uuid] == 4)
        #expect(app.books.first?.position?.timestamp == 99)
        let progression = app.bookByUUID[uuid]?.progress
        #expect(progression != nil && abs(progression! - 0.42) < 0.0001)
        let kept = try await store.annotations(for: uuid)
        #expect(kept.count == 1, "annotations are the reader's, not the download's")
    }

    // MARK: - Reconciliation

    /// The sweep. A download can go without this app deleting it — an Apple TV
    /// keeps them in Caches, which the system may reclaim — and everything
    /// derived from it is then orphaned. The index in particular is the text of
    /// the reader's book, which PRIVACY.md promises is "deleted when you delete
    /// the download or sign out".
    @Test("a file that went behind the model's back takes its question index with it")
    func reconcileDropsTheIndexOfADepartedDownload() async throws {
        let app = AppModel(keychain: InMemoryTokens())
        let uuid = Self.freshUUID()

        // The download is a real book, copied into the real download directory,
        // so the index below is built from the file that is about to vanish.
        let bundle = Bundle(for: BundleMarker.self)
        let fixture = try #require(bundle.url(forResource: "alice", withExtension: "epub"))
        let file = BookContentService.localURL(
            in: try Self.booksDirectory(), bookUUID: uuid, format: .ebook)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: fixture, to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let indexes = URL.temporaryDirectory.appending(path: "issa-reconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: indexes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: indexes) }
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let store = AskIndexStore(directory: indexes)
        // Held strongly for the length of the test: `AppModel.ask` is weak, and
        // a coordinator nobody owns is a sweep that quietly does nothing.
        let coordinator = AskCoordinator(
            store: store, model: ScriptedAnswerModel(), notifier: nil, defaults: defaults)
        app.ask = coordinator

        let source = try BookSource(bookUUID: uuid, fileURL: file)
        _ = try await store.prepare(source: source)
        #expect(await store.isPrepared(source: source), "the index has to exist to be dropped")

        app.refreshDownloadedSet()
        #expect(app.downloadedUUIDs.contains(uuid))

        // Gone, without a `removeDownload` anywhere near it.
        try FileManager.default.removeItem(at: file)
        app.refreshDownloadedSet()

        #expect(!app.downloadedUUIDs.contains(uuid))
        let dropped = await Self.eventually { await !store.isPrepared(source: source) }
        #expect(dropped, "the index outlived the book it was built from")
    }

    /// `resolvePublisherFont` writes a book's embedded face to
    /// `Fonts/<book-uuid>/` on every open and nothing ever removed it. The
    /// second half matters at least as much: the faces at the root of `Fonts/`
    /// were imported by the reader, this is their only copy, and they are no
    /// more the download's than an annotation is.
    @Test("reconciling removes a book's extracted face and leaves the reader's own")
    func reconcileRemovesExtractedFontsOnly() throws {
        let app = AppModel(keychain: InMemoryTokens())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .readaloud)
        defer { try? FileManager.default.removeItem(at: file) }

        let fonts = try #require(CustomFonts.importedDirectory)
        let mine = fonts.appending(path: "imported-\(uuid).otf")
        try Data("not really a font".utf8).write(to: mine)
        defer { try? FileManager.default.removeItem(at: mine) }

        let extracted = CustomFonts.extractedDirectory(bookUUID: uuid)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try Data("nor is this".utf8).write(to: extracted.appending(path: "body.otf"))
        defer { try? FileManager.default.removeItem(at: extracted) }

        app.refreshDownloadedSet()
        #expect(app.downloadedUUIDs.contains(uuid))

        try FileManager.default.removeItem(at: file)
        app.refreshDownloadedSet()

        #expect(!Self.exists(extracted), "the face came out of the book that has gone")
        #expect(Self.exists(mine), "that one is the reader's")
        #expect(Self.exists(fonts), "and so is the folder it lives in")
    }

    /// The ordinary path runs the sweep as well — `removeDownload` refreshes
    /// the set, which is what notices the departure — so the steps have to be
    /// safe to run twice.
    @Test("removing the last edition and reconciling it are the same removal, run twice")
    func removalIsIdempotentWithTheSweep() throws {
        let app = AppModel(keychain: InMemoryTokens())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }

        let extracted = CustomFonts.extractedDirectory(bookUUID: uuid)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try Data("face".utf8).write(to: extracted.appending(path: "body.otf"))
        defer { try? FileManager.default.removeItem(at: extracted) }

        app.refreshDownloadedSet()
        app.removeDownload(SharedFixtures.book("Dracula", uuid: uuid), format: .ebook)

        #expect(!Self.exists(file))
        #expect(!Self.exists(extracted))
        #expect(!app.downloadedUUIDs.contains(uuid))
    }

    // MARK: - The undo window

    /// The mockup asks for an undo toast and says nothing in the section may
    /// start a download. Both can only be true if the bytes are still there
    /// while the toast is up — so the row goes at once and the file goes when
    /// the window closes.
    @Test("a removal inside its undo window has not touched the disk yet")
    func undoWindowDefersTheDeletion() throws {
        let app = AppModel(keychain: InMemoryTokens())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()

        app.removeDownload(bookUUID: uuid, format: .ebook, title: "Dracula",
                           undoWindow: .seconds(600))

        #expect(app.pendingRemoval?.bookUUID == uuid)
        #expect(Self.exists(file), "undo must never have to fetch anything back")

        app.undoPendingRemoval()
        #expect(app.pendingRemoval == nil)
        #expect(Self.exists(file))
    }

    @Test("the window closing deletes what it was holding")
    func theWindowCommits() throws {
        let app = AppModel(keychain: InMemoryTokens())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()

        app.removeDownload(bookUUID: uuid, format: .ebook, title: "Dracula",
                           undoWindow: .seconds(600))
        app.commitPendingRemoval()

        #expect(app.pendingRemoval == nil)
        #expect(!Self.exists(file))
    }

    /// One at a time, like Mail's undo send: a toast that could mean any of
    /// three rows is not an undo, so a second removal commits the first.
    @Test("a second removal commits the first rather than losing it")
    func aSecondRemovalCommitsTheFirst() throws {
        let app = AppModel(keychain: InMemoryTokens())
        let first = Self.freshUUID()
        let second = Self.freshUUID()
        let firstFile = try Self.plant(first, format: .ebook)
        let secondFile = try Self.plant(second, format: .ebook)
        defer {
            for url in [firstFile, secondFile] { try? FileManager.default.removeItem(at: url) }
        }
        app.refreshDownloadedSet()

        app.removeDownload(bookUUID: first, format: .ebook, title: "One",
                           undoWindow: .seconds(600))
        app.removeDownload(bookUUID: second, format: .ebook, title: "Two",
                           undoWindow: .seconds(600))

        #expect(!Self.exists(firstFile), "the first window closed when the second opened")
        #expect(Self.exists(secondFile))
        #expect(app.pendingRemoval?.bookUUID == second)
        app.commitPendingRemoval()
    }

    /// A timer that fired after the account had gone would delete a file
    /// belonging to whoever signed in next.
    @Test("signing out closes an open undo window first")
    func signingOutCommitsAPendingRemoval() async throws {
        let app = AppModel(keychain: InMemoryTokens())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()

        app.removeDownload(bookUUID: uuid, format: .ebook, title: "Dracula",
                           undoWindow: .seconds(600))
        await app.signOut(keepDownloads: true)

        #expect(app.pendingRemoval == nil)
        #expect(!Self.exists(file))
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
