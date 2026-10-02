import Foundation
import ImageIO
import IssaCore
import IssaEPUB
import Testing

@testable import IssaReader_iOS

/// Adding a book from the reader's files: the copy, the checks, the row, and
/// every refusal and notice the copy deck has words for.
@Suite("Adding a book from the reader's files")
@MainActor
struct LocalImportTests {
    // MARK: - What a good file becomes

    @Test("the read-along fixture is added as a narrated book, with no cover to cut")
    func readalongIsAligned() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let url = try local.pick("readalong")

        await local.importAndWait(url)

        let book = try #require(local.library.books.first)
        #expect(local.library.books.count == 1)
        #expect(book.isLocal)
        #expect(book.uuid.isBareUUID)
        #expect(book.hasReadalong, "every file of its narration is MP3, which plays here")
        #expect(book.title == "The Patient Record of the Days")
        #expect(book.byline == "A. Fixture")
        #expect(book.narrationDuration.map { abs($0 - 32.75) < 0.01 } == true)
        let copy = try #require(book.localCopy)
        #expect(copy.fileName == "readalong.epub")
        #expect(copy.fingerprint == (try LocalBookImporter.sha256(of: url)))
        #expect(copy.byteCount == Int64(try Data(contentsOf: url).count))
        #expect(!copy.hasCover)
        #expect(copy.notices.isEmpty)
        #expect(copy.packageIdentifier == "urn:uuid:issa-readalong-fixture")

        let files = local.library.files(for: book.uuid)
        #expect(FileManager.default.fileExists(atPath: files.epub.path))
        #expect(!FileManager.default.fileExists(atPath: files.cover.path))
        #expect(try Data(contentsOf: files.epub) == Data(contentsOf: url), "the copy is the file")
        #expect(FileManager.default.fileExists(atPath: url.path), "the original is never touched")
        #expect(local.incoming().isEmpty, "nothing left in flight")
        // Out of backups, the whole tree: the original is still in Files.
        #expect(try local.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        // The row was written, and a relaunch finds the book.
        let relaunched = local.relaunched()
        await relaunched.load()
        #expect(relaunched.books.map(\.uuid) == [book.uuid])
        #expect(relaunched.missingFiles.isEmpty)
    }

    @Test("a book with a cover gets one cut at import")
    func coverIsCut() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("alice"))

        let book = try #require(local.library.books.first)
        #expect(book.localCopy?.hasCover == true)
        #expect(!book.hasReadalong)
        #expect(book.servableFormats == [.ebook])
        let cover = local.library.files(for: book.uuid).cover
        let source = try #require(CGImageSourceCreateWithURL(cover as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(max(width, height) <= 1200)
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    }

    // MARK: - Already here, and back from a backup

    @Test("the same file a second time is already here: nothing is added")
    func duplicate() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("alice"))
        let first = try #require(local.library.books.first)

        // A second copy under another name: matched by identifier and hash,
        // not by name.
        await local.importAndWait(try local.pick("alice", as: "alice (1).epub"))

        #expect(local.library.books.map(\.uuid) == [first.uuid])
        #expect(local.library.duplicate?.uuid == first.uuid)
        #expect(LocalBooksCopy.alreadyHere(first.title) == "\(first.title) is already on this iPhone.")
        let folders = try FileManager.default.contentsOfDirectory(atPath: local.root.path)
            .filter { !$0.hasPrefix(".") }
        #expect(folders.count == 1, "a second folder was made for a book already here")
        #expect(local.incoming().isEmpty, "the duplicate's copy was left in flight")
        #expect(local.library.imports.isEmpty, "a duplicate leaves no problem row")
    }

    /// A restored device has the row and not the file: the same file chosen
    /// again goes back under the record, with the reader's place.
    @Test("a book whose file went missing is put back by choosing it again")
    func reattach() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let url = try local.pick("readalong")
        await local.importAndWait(url)
        let book = try #require(local.library.books.first)
        let locator = ReadiumLocator(
            href: "OEBPS/ch02.xhtml", type: "application/xhtml+xml",
            locations: .init(progression: 0.5, totalProgression: 0.75))
        #expect(await local.library.writePosition(locator, timestamp: 42, origin: .chosen, for: book.uuid))

        // The backup brought back the store and not the copy.
        try FileManager.default.removeItem(at: local.library.files(for: book.uuid).folder)
        let restored = local.relaunched()
        await restored.load()
        #expect(restored.missingFiles == [book.uuid])

        restored.importBooks([url])
        await restored.importsSettled()

        #expect(restored.missingFiles.isEmpty)
        #expect(restored.books.map(\.uuid) == [book.uuid], "a reattach is the same book, not a new one")
        #expect(restored.books.first?.position?.locator.locations?.totalProgression == 0.75)
        #expect(FileManager.default.fileExists(atPath: restored.files(for: book.uuid).epub.path))
        #expect(restored.duplicate == nil)
    }

    @Test("Add Again with a different book is refused, and says which file it wants")
    func reattachTheWrongBook() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("readalong", as: "emma.epub"))
        let book = try #require(local.library.books.first)
        try FileManager.default.removeItem(at: local.library.files(for: book.uuid).epub)
        let restored = local.relaunched()
        await restored.load()

        restored.importBooks([try local.pick("alice")], reattaching: book.uuid)
        await restored.importsSettled()

        let row = try #require(restored.imports.first)
        #expect(row.stage == .failed(.notTheSameBook(expectedFileName: "emma.epub")))
        #expect(LocalImportError.notTheSameBook(expectedFileName: "emma.epub").action == .chooseAgain)
        #expect(restored.books.count == 1)
        #expect(restored.missingFiles == [book.uuid])
    }

    // MARK: - Refusals

    @Test("a text file called .epub is not an EPUB, and a PDF says it is one")
    func notAnEPUB() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let renamed = try local.pick(Data("Notes to self, not a book.".utf8), as: "notes.epub")
        let pdf = try local.pick(Data("%PDF-1.7".utf8), as: "Field Notes.pdf")

        local.library.importBooks([renamed, pdf])
        await local.library.importsSettled()

        let stages = local.library.imports.map(\.stage)
        #expect(stages == [.failed(.notAnEPUB(kind: nil)), .failed(.notAnEPUB(kind: "a PDF"))])
        #expect(LocalImportError.notAnEPUB(kind: "a PDF").reason
            == "This is a PDF. Issa Reader can open EPUB books only.")
        #expect(local.library.books.isEmpty)
        #expect(local.incoming().isEmpty)
    }

    @Test("a folder is refused as a folder")
    func folder() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let folder = local.picked.appending(path: "Dracula.epub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let row = await local.importAndWait(folder)
        #expect(row?.stage == .failed(.folder))
        #expect(LocalImportError.folder.title == "This is a folder")
    }

    /// Built in the test: an otherwise good book carrying Adobe's licence.
    @Test("a copy-protected book is refused, with the words that explain DRM")
    func drm() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let locked = TestEPUB.data(
            title: "The Glass Hours",
            chapters: [.init(id: "ch1", title: "One", body: "<p>Words behind a lock.</p>")],
            extras: [("META-INF/rights.xml", Data("<rights/>".utf8))])

        let row = await local.importAndWait(try local.pick(locked, as: "The Glass Hours.epub"))

        #expect(row?.stage == .failed(.drmProtected))
        #expect(LocalImportError.drmProtected.reason.hasPrefix("It has DRM, a lock some shops add"))
        #expect(LocalImportError.drmProtected.action == nil)
        #expect(local.library.books.isEmpty)
        #expect(local.incoming().isEmpty, "the locked copy was left behind")
    }

    @Test("a book with no readable chapter is damaged")
    func damaged() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        // A spine whose only item names a file the archive does not hold.
        let hollow = TestEPUB.data(chapters: [.init(id: "ch1", title: "One", body: "<p>x</p>")])
        var bytes = hollow
        let from = Data("OEBPS/ch1.xhtml".utf8), to = Data("OEBPS/zz1.xhtml".utf8)
        // Renaming the member in both of its headers leaves the manifest
        // pointing at nothing.
        while let range = bytes.range(of: from) { bytes.replaceSubrange(range, with: to) }

        let row = await local.importAndWait(try local.pick(bytes, as: "middlemarch.epub"))
        #expect(row?.stage == .failed(.damaged))
    }

    @Test("a book over the limit is too large, and says how large")
    func tooLarge() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        local.library.importer.maximumSize = 1024
        let url = try local.pick("readalong")
        let size = Int64(try Data(contentsOf: url).count)

        let row = await local.importAndWait(url)
        #expect(row?.stage == .failed(.tooLarge(bytes: size)))
        #expect(LocalImportError.tooLarge(bytes: size).action == nil)
    }

    @Test("not enough room says what is needed and what is free, and offers Try Again")
    func notEnoughSpace() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        local.library.importer.availableSpace = { _ in 1000 }
        local.library.importer.spaceMargin = 0
        let url = try local.pick("readalong")
        let size = Int64(try Data(contentsOf: url).count)

        let row = await local.importAndWait(url)
        let error = LocalImportError.notEnoughSpace(needed: size, free: 1000)
        #expect(row?.stage == .failed(error))
        #expect(error.action == .tryAgain)
        #expect(error.title == "Not enough space on this iPhone")

        // Room made, the same row tried again: it is added.
        local.library.importer.availableSpace = { _ in Int64.max / 2 }
        let id = try #require(row?.id)
        local.library.retry(id)
        await local.library.importsSettled()
        #expect(local.library.books.count == 1)
    }

    /// Narration counts towards the room needed: extraction on first open
    /// roughly doubles a read-along.
    @Test("a read-along needs room for its narration as well as its copy")
    func narrationNeedsRoom() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let url = try local.pick("readalong")
        let size = Int64(try Data(contentsOf: url).count)
        local.library.importer.spaceMargin = 0
        // Room for the copy, not for the copy and its audio.
        local.library.importer.availableSpace = { _ in size + 10 }

        let row = await local.importAndWait(url)
        guard case let .failed(.notEnoughSpace(needed, _)) = row?.stage else {
            Issue.record("expected a refusal for space, got \(String(describing: row?.stage))")
            return
        }
        #expect(needed > size)
    }

    // MARK: - Notices

    @Test("narration this device cannot play is dropped, with a notice")
    func unplayableNarration() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let opus = TestEPUB.data(
            title: "The Opus Narration",
            chapters: [.init(id: "ch1", title: "One", body: "<p><span id=\"s0\">Spoken.</span></p>",
                             narrated: ["s0"])],
            audio: Data(repeating: 0, count: 512), audioMediaType: "audio/opus")

        await local.importAndWait(try local.pick(opus, as: "moby-dick.epub"))

        let book = try #require(local.library.books.first)
        #expect(!book.hasReadalong, "narration that plays nothing must not be offered")
        #expect(book.localCopy?.notices == [.narrationUnplayable])
        #expect(LocalBooksCopy.notice(.narrationUnplayable)
            == "Added without narration. Its audio is in a format this iPhone can’t play, so the book reads as text only.")

        // OK clears it for good.
        local.library.dismissNotice(.narrationUnplayable, for: book.uuid)
        #expect(local.library.books.first?.localCopy?.notices.isEmpty == true)
    }

    @Test("a fixed-layout book is added, with a notice")
    func fixedLayout() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let fixed = TestEPUB.data(
            title: "A Child's Picture Book",
            chapters: [.init(id: "ch1", title: "One", body: "<p>Pictures.</p>")],
            metadata: "<meta property=\"rendition:layout\">pre-paginated</meta>")

        await local.importAndWait(try local.pick(fixed, as: "verses.epub"))

        let book = try #require(local.library.books.first)
        #expect(book.localCopy?.isFixedLayout == true)
        #expect(book.localCopy?.notices == [.fixedLayout])
    }

    // MARK: - Cancelling, and what a crash leaves

    /// The chunked copy — what a book from another volume gets — is held
    /// after its first chunk, the import cancelled, and the copy let go.
    @Test("cancelling mid-copy leaves no trace and no message")
    func cancelMidCopy() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let started = OnceFlag()
        let proceed = DispatchSemaphore(value: 0)
        let once = OnceFlag()
        local.library.importer.allowsClone = false
        local.library.importer.chunkSize = 256
        local.library.importer.afterChunk = {
            guard once.claim() else { return }
            _ = started.claim()
            // On the copy's own queue, never a task's: this is the hold.
            proceed.wait()
        }
        let url = try local.pick("readalong")
        local.library.importBooks([url])
        let id = try #require(local.library.imports.first?.id)

        // Bounded: the copy runs on its own queue and says when it is held.
        let reached = await Self.eventually(within: .seconds(10)) { started.wasClaimed }
        try #require(reached, "the copy never started")
        local.library.cancelImport(id)
        proceed.signal()
        await local.library.importsSettled()

        #expect(local.library.imports.isEmpty, "a cancelled file leaves no row")
        #expect(local.library.books.isEmpty)
        #expect(local.incoming().isEmpty, "the half-made copy was left in flight")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: local.root.path)) ?? []
        #expect(folders.filter { !$0.hasPrefix(".") }.isEmpty)
    }

    @Test("a launch clears what a crash left: copies in flight and folders with no row")
    func crashLeftovers() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let incoming = LocalBookFiles.incoming(in: local.root)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: incoming.appending(path: "\(UUID().uuidString).epub"))
        let orphan = LocalBookFiles(bookUUID: UUID().uuidString.lowercased(), root: local.root)
        try FileManager.default.createDirectory(at: orphan.folder, withIntermediateDirectories: true)
        try Data("book".utf8).write(to: orphan.epub)

        await local.library.load()

        #expect(local.incoming().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: orphan.folder.path))
        #expect(local.library.isLoaded)
        #expect(local.library.books.isEmpty)
    }

    // MARK: - Removing

    @Test("removing takes the book off the list at once, and undo puts it back")
    func removeAndUndo() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("alice"))
        let book = try #require(local.library.books.first)
        var released: [String] = []
        local.library.onRemove = { released.append($0) }

        local.library.remove([book.uuid])
        #expect(local.library.books.isEmpty)
        #expect(released == [book.uuid], "whatever was reading it is let go at once")
        #expect(local.library.pendingRemoval?.message
            == "Removed Alice's Adventures in Wonderland. Original kept in Files.")
        #expect(local.library.uuids.contains(book.uuid), "still the device's until it goes")

        local.library.undoRemoval()
        #expect(local.library.books.map(\.uuid) == [book.uuid])
        #expect(FileManager.default.fileExists(atPath: local.library.files(for: book.uuid).epub.path))
    }

    @Test("a removal carried out deletes the copy, the place, the marks and the anchor")
    func removeCommitted() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("readalong"))
        let book = try #require(local.library.books.first)
        let locator = ReadiumLocator(
            href: "OEBPS/ch01.xhtml", type: "application/xhtml+xml",
            locations: .init(progression: 0.2, totalProgression: 0.1))
        #expect(await local.library.writePosition(locator, timestamp: 1, origin: .chosen, for: book.uuid))
        await local.library.recordAudioAnchor(
            AudioAnchor(audioHref: "OEBPS/Audio/track1.mp3", offset: 2, writtenAt: 1), for: book.uuid)
        let mark = Annotation(
            bookUUID: book.uuid, kind: .highlight, locator: locator, excerpt: "kept its own record")
        local.library.save(mark)
        let store = try LibraryStore(serverKey: LibraryStore.deviceBooksKey, directory: local.storeDirectory)
        let saved = await Self.eventually { ((try? await store.annotations(for: book.uuid)) ?? []).count == 1 }
        try #require(saved, "the highlight has to be on disk for its deletion to mean anything")
        var forgotten: [String] = []
        local.library.onForget = { forgotten.append($0) }
        // Something written to the folder after import, as narration would be.
        let narration = local.library.files(for: book.uuid).narration
        try FileManager.default.createDirectory(at: narration, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: narration.appending(path: "a.mp3"))

        local.library.remove([book.uuid])
        local.library.commitPendingRemoval()

        #expect(forgotten == [book.uuid])
        #expect(!FileManager.default.fileExists(atPath: local.library.files(for: book.uuid).folder.path))
        let gone = await Self.eventually {
            let row = try? await store.book(book.uuid)
            let marks = (try? await store.annotations(for: book.uuid)) ?? []
            let anchor = try? await store.audioAnchor(forBook: book.uuid)
            return row == nil && marks.isEmpty && anchor == nil
        }
        #expect(gone, "the row, highlights or anchor outlived the book")
        // And a write arriving now is refused, not written back.
        #expect(!(await local.library.writePosition(locator, timestamp: 2, origin: .chosen, for: book.uuid)))
    }

    /// Bounded, never an unbounded yield loop.
    static func eventually(
        within timeout: Duration = .seconds(2), _ condition: () async -> Bool,
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}

/// True the first time it is claimed, from any thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }

    var wasClaimed: Bool { lock.withLock { claimed } }
}
