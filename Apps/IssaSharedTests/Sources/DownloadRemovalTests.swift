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

    /// The half of a two-edition removal that had no owner.
    ///
    /// The publisher face and the question index are derived from the book's
    /// *text*, and either edition carries it — so releasing them because one of
    /// the two went destroyed data belonging to the copy still on the device.
    /// `DownloadsInventory.departed` had already written the rule down — "a book
    /// that lost one of two editions has not departed" — and the deletion path
    /// was the one place not honouring it.
    ///
    /// Nothing on screen changes when this is wrong, which is why it needs a
    /// test: the reader finds out on the next open, when the book is set in the
    /// fallback face and every question it had been indexed for has to be
    /// indexed again.
    @Test("removing one of two editions keeps the face and index of the other")
    func removingOneEditionKeepsTheBooksDerivedFiles() async throws {
        let app = AppModel(keychain: InMemoryTokens())
        let uuid = Self.freshUUID()
        // A real book for the ebook, because the index below is built by parsing
        // it — and the point of the test is that the index outlives it.
        let bundle = Bundle(for: BundleMarker.self)
        let fixture = try #require(bundle.url(forResource: "alice", withExtension: "epub"))
        let ebook = BookContentService.localURL(
            in: try Self.booksDirectory(), bookUUID: uuid, format: .ebook)
        try? FileManager.default.removeItem(at: ebook)
        try FileManager.default.copyItem(at: fixture, to: ebook)
        let readaloud = try Self.plant(uuid, format: .readaloud, bytes: 64)
        defer { for url in [ebook, readaloud] { try? FileManager.default.removeItem(at: url) } }

        let extracted = CustomFonts.extractedDirectory(bookUUID: uuid)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let face = extracted.appending(path: "body.otf")
        try Data("face".utf8).write(to: face)
        defer { try? FileManager.default.removeItem(at: extracted) }

        let indexes = URL.temporaryDirectory.appending(path: "issa-editions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: indexes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: indexes) }
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = AskIndexStore(directory: indexes)
        // Held strongly: `AppModel.ask` is weak, and a coordinator nobody owns
        // is a removal that quietly does nothing and a test that proves nothing.
        let coordinator = AskCoordinator(
            store: store, model: ScriptedAnswerModel(), notifier: nil, defaults: defaults)
        app.ask = coordinator
        let source = try BookSource(bookUUID: uuid, fileURL: ebook)
        _ = try await store.prepare(source: source)
        // The index *file*, not `isPrepared`: that re-reads the fingerprint of
        // the EPUB it was built from, so once the ebook has gone it answers
        // false whether or not the index survived — which is precisely the
        // distinction this test exists to draw.
        let index = store.indexURL(for: uuid)
        #expect(Self.exists(index), "the index has to exist to be kept")

        app.refreshDownloadedSet()
        app.removeDownload(bookUUID: uuid, format: .ebook)

        #expect(!Self.exists(ebook), "the edition asked for is the one that goes")
        #expect(Self.exists(readaloud))
        #expect(app.downloadedUUIDs.contains(uuid), "the book has not departed")
        #expect(Self.exists(face), "the face belongs to the read-along still on disk")
        // Given a moment to be wrong: the removal hands the index to the store's
        // actor, so asserting straight away would pass whether or not it went.
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.exists(index),
                "the index was built from text that is still on the device")

        // And when the last edition carrying text goes, both do go.
        app.removeDownload(bookUUID: uuid, format: .readaloud)
        #expect(!Self.exists(face))
        let indexPath = index.path
        let dropped = await Self.eventually {
            !FileManager.default.fileExists(atPath: indexPath)
        }
        #expect(dropped)
    }

    /// An audiobook carries no text, so it cannot be what a face or an index was
    /// derived from — a book left with only one has nothing behind either.
    @Test("an audiobook left on the device does not keep a face alive")
    func anAudiobookIsNotTextOnTheDevice() throws {
        let app = AppModel(keychain: InMemoryTokens())
        let uuid = Self.freshUUID()
        let ebook = try Self.plant(uuid, format: .ebook)
        let audiobook = try Self.plant(uuid, format: .audiobook, bytes: 64)
        defer { for url in [ebook, audiobook] { try? FileManager.default.removeItem(at: url) } }

        let extracted = CustomFonts.extractedDirectory(bookUUID: uuid)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let face = extracted.appending(path: "body.otf")
        try Data("face".utf8).write(to: face)
        defer { try? FileManager.default.removeItem(at: extracted) }

        app.refreshDownloadedSet()
        app.removeDownload(bookUUID: uuid, format: .ebook)

        #expect(Self.exists(audiobook), "the edition not asked for stays")
        #expect(!Self.exists(face), "nothing left on the device has any text in it")
    }

    /// The sweep's worst case, and the one it is least equipped to notice.
    ///
    /// `downloadedBookUUIDs` coalesced a failed directory read to an empty set,
    /// and every book the app knew about was then in `previous` and in no
    /// `current` — so the sweep concluded that the reader had deleted their
    /// entire library and deleted every book's question index, extracted
    /// narration and publisher font to match. None of that is re-downloadable:
    /// the index is minutes of on-device work, and the narration is hundreds of
    /// megabytes. The files themselves were untouched, which is what made it
    /// invisible until the next time a book was opened.
    ///
    /// An unreadable directory is a fact about this moment — a permissions
    /// fault, a detached volume, a device still unlocking after a restart — and
    /// says nothing about what is on the disk. So: keep the last set, run no
    /// sweep, and try again on the next refresh.
    @Test("a downloads directory that cannot be read is not an empty library")
    func anUnreadableDirectoryIsNotADeparture() throws {
        let app = AppModel(keychain: InMemoryTokens())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }

        let extracted = CustomFonts.extractedDirectory(bookUUID: uuid)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let face = extracted.appending(path: "body.otf")
        try Data("face".utf8).write(to: face)
        defer { try? FileManager.default.removeItem(at: extracted) }

        app.refreshDownloadedSet()
        #expect(app.downloadedUUIDs.contains(uuid))

        // Unreadable, and emphatically not empty. Restored unconditionally: this
        // is the app's real downloads directory, and leaving it at 0o000 would
        // break every test after it rather than only this one.
        let directory = try Self.booksDirectory()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }

        app.refreshDownloadedSet()

        #expect(app.downloadedUUIDs.contains(uuid),
                "the last set it could read is a better answer than a wrong one")
        #expect(Self.exists(face), "the sweep deleted a face for a book that never left")
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

    /// The X on a transfer row says "Cancel" and is drawn on a progress bar,
    /// and it ran a whole book's removal — so cancelling a download started by
    /// mistake released the publisher face and question index of a *different*
    /// edition of that book already on the device. A tap on a cross belonging
    /// to a bar that has not finished is not a decision about anything the
    /// reader already has.
    @Test("cancelling a transfer leaves the book's other edition untouched")
    func cancellingATransferIsNotABookRemoval() throws {
        let app = AppModel(keychain: InMemoryTokens())
        let uuid = Self.freshUUID()
        let ebook = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: ebook) }

        let extracted = CustomFonts.extractedDirectory(bookUUID: uuid)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let face = extracted.appending(path: "body.otf")
        try Data("face".utf8).write(to: face)
        defer { try? FileManager.default.removeItem(at: extracted) }

        app.refreshDownloadedSet()
        #expect(app.downloadedUUIDs.contains(uuid))

        // The read-along the reader started by accident. No file for it, which
        // is what a transfer still running looks like on disk.
        app.cancelDownload(DownloadManager.Job(bookUUID: uuid, format: .readaloud))

        #expect(Self.exists(ebook), "the edition already on the device is not what was cancelled")
        #expect(Self.exists(face), "the face belongs to the ebook, which nobody asked to remove")
        #expect(app.downloadedUUIDs.contains(uuid))
    }

    /// Restarting a download inside the undo window is the reader changing
    /// their mind, and nothing was telling the window that.
    ///
    /// The timer was armed by the removal and never disarmed, so the file the
    /// new transfer was arriving into was deleted six seconds later by a
    /// decision the reader had already reversed. On screen it looked like a
    /// download that simply stopped: no error, because from the app's point of
    /// view nothing had failed.
    @Test("starting a download takes back a removal still inside its window")
    func startingADownloadCancelsAPendingRemoval() async throws {
        let app = AppModel(keychain: InMemoryTokens())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()

        app.removeDownload(bookUUID: uuid, format: .ebook, title: "Dracula",
                           undoWindow: .seconds(600))
        #expect(app.pendingRemoval?.bookUUID == uuid)

        // No session, so no transfer actually starts — `download` returns false
        // at the `downloads` guard. The pending removal has to be taken back
        // before that point is even reached, because the tap is the statement.
        await app.resumeDownload(DownloadManager.Job(bookUUID: uuid, format: .ebook))

        #expect(app.pendingRemoval == nil, "the window is still armed over a book being fetched")
        app.commitPendingRemoval()
        #expect(Self.exists(file), "the window closed on a removal the reader had reversed")
    }

    /// Only the same edition. A removal of one book says nothing about a
    /// download of another, and clearing the window on any download at all
    /// would make the toast lie about what it is holding.
    @Test("starting a different download leaves the window alone")
    func adifferentDownloadLeavesTheWindowAlone() async throws {
        let app = AppModel(keychain: InMemoryTokens())
        let removed = Self.freshUUID()
        let other = Self.freshUUID()
        let file = try Self.plant(removed, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()

        app.removeDownload(bookUUID: removed, format: .ebook, title: "Dracula",
                           undoWindow: .seconds(600))
        await app.resumeDownload(DownloadManager.Job(bookUUID: other, format: .ebook))
        #expect(app.pendingRemoval?.bookUUID == removed)

        // And the same book in a different edition is a different job too.
        await app.resumeDownload(DownloadManager.Job(bookUUID: removed, format: .readaloud))
        #expect(app.pendingRemoval?.bookUUID == removed)

        app.commitPendingRemoval()
        #expect(!Self.exists(file))
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
