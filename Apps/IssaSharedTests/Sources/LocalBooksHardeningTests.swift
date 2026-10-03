import Foundation
import IssaCore
import SQLite3
import SwiftUI
import Testing
import UIKit

@testable import IssaReader_iOS

/// What a file from the reader's own folders, or a device store in a bad way,
/// must not be able to do to the list: crash it, empty it, or leave it saying
/// something stale. The 1.4.0 review's local-books findings, one test each.
@Suite("Books from the reader's files, against bad input", .serialized)
@MainActor
struct LocalBooksHardeningTests {
    static let narrated = TestEPUB.Chapter(
        id: "ch1", title: "One", body: "<p><span id=\"s0\">The night shift began.</span></p>",
        narrated: ["s0"])

    // MARK: - R-01: a narration length no clock can show

    /// `media:duration` is the book's word for its own length; 1e21 seconds is
    /// finite, passes every check the parser makes, and trapped the row the
    /// moment it was drawn. The one clip the overlay plays is what it lasts.
    @Test("an absurd media:duration is not what the book is said to last")
    func absurdDurationIsNotKept() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let data = TestEPUB.data(
            title: "The Long Night Shift", chapters: [Self.narrated],
            audio: Data(repeating: 0, count: 512),
            metadata: "<meta property=\"media:duration\">1e21s</meta>")

        await local.importAndWait(try local.pick(data, as: "night-shift.epub"))

        let book = try #require(local.library.books.first)
        #expect(book.hasReadalong, "the narration plays; only its stated length is absurd")
        let seconds = try #require(book.narrationDuration)
        #expect(abs(seconds - 1) < 0.01, "kept \(seconds) s as the narration's length")
    }

    @Test("an absurd length with no sane clip behind it is clamped, never dropped")
    func absurdTimelineIsClamped() {
        let ceiling = LocalBookImporter.longestNarration
        #expect(LocalBookImporter.narrationLength(declared: 1e21, timeline: 1) == 1)
        #expect(LocalBookImporter.narrationLength(declared: nil, timeline: 1e21) == ceiling)
        #expect(LocalBookImporter.narrationLength(declared: .nan, timeline: .infinity) == ceiling)
        #expect(LocalBookImporter.narrationLength(declared: 3600, timeline: 1e21) == 3600)
        #expect(LocalBookImporter.narrationLength(declared: nil, timeline: 0) == nil)
        #expect(LocalBookImporter.narrationLength(declared: 0, timeline: 0) == nil)
    }

    /// A row an earlier build stored with the absurd length still draws: the
    /// line and Book info say "Narrated" with no length rather than trap.
    @Test("a stored absurd length draws the row and Book info")
    func storedAbsurdLengthDraws() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let book = Book.local(
            uuid: UUID().uuidString.lowercased(),
            metadata: LocalBookMetadata(title: "The Long Night Shift"),
            narrationDuration: 1e21,
            copy: LocalCopy(fileName: "night-shift.epub", fingerprint: "f", byteCount: 4096, importedAt: Date()))
        try #require(book.hasReadalong)

        #expect(LocalBooksCopy.narrated(seconds: 1e21) == "Narrated")
        #expect(LocalBooksCopy.narrated(seconds: .infinity) == "Narrated")
        #expect(LocalBooksCopy.narrated(seconds: 25_440) == "Narrated · 7 h 4 min")
        #expect(LocalBooksCopy.narrated(seconds: 20) == "Narrated · 1 min")
        let facts = LocalBookFacts(book: book, size: 4096, isMissing: false, isPlaying: false)
        #expect(facts.narration == "Narrated")
        #expect(facts.spoken.contains("Narrated"))

        let host = UIHostingController(rootView: AnyView(VStack {
            LocalBookRow(
                book: book, size: 4096, isMissing: false, isPlaying: false, isHighlighted: false,
                onNoticeAction: { _ in })
            LocalBookInfoView(book: book) {}
        }.environment(local.library)))
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.view.window != nil)
    }

    // MARK: - R-02: a store that cannot be read is not an empty library

    @Test("a device store that will not open leaves every book's folder alone")
    func unreadableStoreKeepsFolders() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("alice"))
        let book = try #require(local.library.books.first)
        let storeURL = try #require(await local.library.store?.url)

        // What a corrupt file, or a later build's migration that failed on a
        // full disk, leaves behind.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
        }
        try Data("not a database, whatever its name says".utf8).write(to: storeURL)
        let relaunched = local.relaunched()
        try #require(relaunched.store == nil, "the store opened; this test needs one that does not")

        await relaunched.load()

        #expect(FileManager.default.fileExists(atPath: relaunched.files(for: book.uuid).epub.path),
                "the only copy of the book was deleted as a crash leftover")
        #expect(relaunched.uuids.contains(book.uuid),
                "an account's exit would take the kept book's index and style")
    }

    @Test("a row that will not decode keeps its folder, and the rest load")
    func undecodableRowKeepsItsFolder() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("alice"))
        await local.importAndWait(try local.pick("readalong"))
        let bad = try #require(local.library.books.first { $0.title.hasPrefix("Alice") })
        let good = try #require(local.library.books.first { !$0.title.hasPrefix("Alice") })
        let storeURL = try #require(await local.library.store?.url)

        // A row shape a newer build wrote, as far as this one can tell.
        try Self.execute("UPDATE book SET json = x'7B7D' WHERE uuid = '\(bad.uuid)'", at: storeURL)
        let relaunched = local.relaunched()
        await relaunched.load()

        #expect(relaunched.books.map(\.uuid) == [good.uuid])
        #expect(FileManager.default.fileExists(atPath: relaunched.files(for: bad.uuid).epub.path),
                "the folder of a row this build could not read was deleted")
        #expect(FileManager.default.fileExists(atPath: relaunched.files(for: good.uuid).epub.path))
        #expect(relaunched.uuids.contains(bad.uuid))
    }

    /// One statement against a SQLite file, outside the store.
    static func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
        try #require(sqlite3_changes(db) == 1)
    }

    // MARK: - R-27: an undo that has nothing left to do is not offered

    @Test("after the toast's Undo, or the removal carried out, Edit › Undo offers nothing")
    func undoIsWithdrawn() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("alice"))
        let book = try #require(local.library.books.first)
        let undo = Self.eventUndoManager()

        Self.inOneEvent(undo) { local.library.remove([book.uuid], undoManager: undo) }
        try #require(undo.canUndo)
        local.library.undoRemoval()
        #expect(!undo.canUndo, "Undo Remove still offered after the toast's Undo")
        #expect(local.library.books.map(\.uuid) == [book.uuid])

        Self.inOneEvent(undo) { local.library.remove([book.uuid], undoManager: undo) }
        try #require(undo.canUndo)
        local.library.commitPendingRemoval()
        #expect(!undo.canUndo, "Undo Remove still offered after the removal was carried out")
    }

    /// An undo manager whose groups this test closes, as a window's closes
    /// one at the end of each event. Its entries are withdrawn only from
    /// closed groups, and the toast's Undo, or the six seconds running out,
    /// is always a later event than the removal.
    static func eventUndoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    /// `body` as one event's work: its own undo group, closed at the end.
    static func inOneEvent(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    // MARK: - R-28: a file put back says what is true of it now

    @Test("a file put back under a restored record carries its own notices")
    func reattachCarriesNotices() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let opus = TestEPUB.data(
            title: "The Opus Narration", chapters: [Self.narrated],
            audio: Data(repeating: 0, count: 512), audioMediaType: "audio/opus")
        let url = try local.pick(opus, as: "opus.epub")
        await local.importAndWait(url)
        let book = try #require(local.library.books.first)
        try #require(book.localCopy?.notices == [.narrationUnplayable])
        // Read, and dismissed: the restored record carries none.
        local.library.dismissNotice(.narrationUnplayable, for: book.uuid)
        let cleared = await LocalImportTests.eventually {
            let store = local.library.store
            return (try? await store?.book(book.uuid))?.localCopy?.notices.isEmpty == true
        }
        try #require(cleared)
        try FileManager.default.removeItem(at: local.library.files(for: book.uuid).folder)
        let restored = local.relaunched()
        await restored.load()
        try #require(restored.missingFiles == [book.uuid])

        restored.importBooks([url], reattaching: book.uuid)
        await restored.importsSettled()

        #expect(restored.books.first?.localCopy?.notices == [.narrationUnplayable],
                "the book stopped narrating with nothing on its row to say why")
    }

    // MARK: - R-30: ⌘⌫ with no row focused removes nothing

    @Test("⌘⌫ removes only the row the keyboard is on")
    func commandDeleteNeedsAFocusedRow() {
        let books = [SharedFixtures.book("Dracula", uuid: "11111111-1111-4111-8111-111111111111")]
        #expect(LocalBooksKeyboard.removalTarget(focused: nil) == nil)
        #expect(LocalBooksKeyboard.infoTarget(focused: nil, books: books) == books[0].uuid, "⌘I may still guess")
        #expect(LocalBooksKeyboard.removalTarget(focused: books[0].uuid) == books[0].uuid)
    }

    // MARK: - R-19: a description written as markup

    @Test("a description Calibre wrote as markup reads as text in Book info")
    func descriptionMarkupIsRendered() throws {
        let about = try #require(LocalBookInfoView.aboutText(
            "<div><p>A tale of salt &amp; ash.</p><p>Second <i>part</i>.</p></div>"))
        #expect(!about.contains("<"), "tags on screen: \(about)")
        #expect(!about.contains("&amp;"))
        #expect(about.contains("A tale of salt & ash."))
        #expect(about.contains("Second part."))
        #expect(LocalBookInfoView.aboutText("<p> </p>") == nil)
        #expect(LocalBookInfoView.aboutText(nil) == nil)
    }

    // MARK: - A book from another volume

    /// What a USB drive or a network share gets: not a clone, a chunked copy.
    /// It read past the end of the file as a failure, so every such book was
    /// refused as "Couldn't copy this book".
    @Test("a book that cannot be cloned is copied to its end and added")
    func chunkedCopyReachesTheEnd() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        local.library.importer.allowsClone = false
        let url = try local.pick("readalong")

        let row = await local.importAndWait(url)

        #expect(row?.stage != .failed(.copyFailed), "the chunked copy failed at the end of the file")
        let book = try #require(local.library.books.first)
        #expect(try Data(contentsOf: local.library.files(for: book.uuid).epub) == Data(contentsOf: url))
        #expect(book.localCopy?.fingerprint == (try LocalBookImporter.sha256(of: url)))
    }

    // MARK: - R-63: the copy says how far it has got, not every megabyte

    @Test("the chunked copy reports whole percents only, and hashes as it copies")
    func copyReportsArePercents() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        var importer = local.library.importer
        importer.allowsClone = false
        importer.chunkSize = 16
        let url = try local.pick("readalong")
        let reports = StageLog()

        let prepared = try await importer.run(url, id: UUID()) { reports.append($0) }
        defer { prepared.discard() }

        let fractions = reports.copying
        #expect(!fractions.isEmpty)
        #expect(fractions.count <= 101, "\(fractions.count) progress reports for one small file")
        let percents = fractions.map { Int(($0 * 100).rounded(.down)) }
        #expect(percents == percents.sorted() && Set(percents).count == percents.count,
                "a report that did not move the whole percent")
        #expect(prepared.fingerprint == (try LocalBookImporter.sha256(of: url)))
    }
}

/// Stages reported from the importer's own queue.
final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [LocalImport.Stage] = []

    func append(_ stage: LocalImport.Stage) { lock.withLock { stages.append(stage) } }

    var copying: [Double] {
        lock.withLock { stages.compactMap { if case let .copying(f) = $0 { f } else { nil } } }
    }
}
