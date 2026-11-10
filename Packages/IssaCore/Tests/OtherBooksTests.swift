import Foundation
import Testing

@testable import IssaCore

/// The other books in progress the widget lists beside the current one: which
/// are chosen, when a change is worth a widget reload, and where their covers
/// live.
@Suite("The widget's other books")
struct OtherBooksTests {
    /// Decoded, like every other fixture: the model has no public initialiser.
    func book(
        _ title: String, status: String? = nil, progress: Double? = nil,
        timestamp: Double = 0, audiobook: Bool = false,
    ) -> Book {
        var json: [String: Any] = [
            "uuid": title.lowercased(), "title": title,
            "authors": [["uuid": "a", "name": "Author of \(title)"]], "narrators": [], "creators": [],
            "collections": [], "identifiers": [], "tags": [], "series": [],
        ]
        if let status { json["status"] = ["uuid": status, "name": status] }
        if let progress {
            json["position"] = [
                "locator": ["href": "a", "type": "t", "locations": ["totalProgression": progress]],
                "timestamp": timestamp,
            ]
        }
        if audiobook { json["audiobook"] = ["uuid": "a", "filepath": "a.m4b", "identifiers": []] }
        return try! JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func ids(_ books: [OtherBook]) -> [String] { books.map(\.bookID) }

    // MARK: - Which books

    @Test("most recently positioned first, never the current book")
    func orderAndExclusion() {
        let books = [
            book("Old", status: "Reading", progress: 0.2, timestamp: 100),
            book("Current", status: "Reading", progress: 0.4, timestamp: 900),
            book("New", status: "Reading", progress: 0.1, timestamp: 500),
        ]
        #expect(ids(OtherBook.selection(from: books, excluding: "current")) == ["new", "old"])
        #expect(ids(OtherBook.selection(from: books, excluding: nil)) == ["current", "new", "old"])
    }

    @Test("a uuid listed twice is one book, the first occurrence, order kept")
    func duplicateUUIDs() {
        let books = [
            book("Dup", status: "Reading", progress: 0.3, timestamp: 800),
            book("Other", status: "Reading", progress: 0.2, timestamp: 700),
            book("Dup", status: "Reading", progress: 0.1, timestamp: 100),
        ]
        let list = OtherBook.selection(from: books, excluding: nil)
        #expect(ids(list) == ["dup", "other"])
        #expect(list.first?.progress == 0.3)
    }

    @Test("a finished, to-read or never-started book is not in progress")
    func stages() {
        let books = [
            book("Done", status: "Read", progress: 1, timestamp: 400),
            book("Later", status: "To read", progress: 0.3, timestamp: 300),
            book("Marked", status: "Reading"),
            book("Mid", status: "Reading", progress: 0.5, timestamp: 200),
            // No status: filed by its position, as the shelf does.
            book("Bare", progress: 0.6, timestamp: 100),
        ]
        #expect(ids(OtherBook.selection(from: books, excluding: nil)) == ["mid", "bare"])
    }

    @Test("a book from the reader's own files never reaches the widget")
    func localBooksAreLeftOut() {
        var local = Book.local(
            uuid: "local-one", metadata: LocalBookTests.metadata, narrationDuration: nil,
            copy: LocalBookTests.copy())
        local.adopt(
            position: ReadiumLocator(
                href: "a", type: "t", locations: .init(progression: 0.5, totalProgression: 0.5)),
            timestamp: 9_000)
        #expect(local.isLocal)
        #expect(LibraryDerivation(books: [local]).continueReading.count == 1)   // it is in progress
        let chosen = OtherBook.selection(
            from: [local, book("Served", status: "Reading", progress: 0.2, timestamp: 1)], excluding: nil)
        #expect(ids(chosen) == ["served"])
    }

    @Test("at most four")
    func cap() {
        let books = (1...7).map { book("B\($0)", status: "Reading", progress: 0.1, timestamp: Double($0)) }
        #expect(ids(OtherBook.selection(from: books, excluding: nil)) == ["b7", "b6", "b5", "b4"])
        #expect(ids(OtherBook.selection(from: books, excluding: "b7")) == ["b6", "b5", "b4", "b3"])
    }

    @Test("the fields the widget draws, and the shape it learnt")
    func fields() {
        let books = [
            book("Narrated", status: "Reading", progress: 0.426, timestamp: 2, audiobook: true),
            book("Printed", status: "Reading", progress: 0.1, timestamp: 1),
        ]
        let first = OtherBook.selection(from: books, excluding: nil)
        #expect(first[0].title == "Narrated")
        #expect(first[0].author == "Author of Narrated")
        #expect(first[0].percent == 43)
        #expect(first[0].coverIsSquare)          // audiobook art is asked for first
        #expect(!first[1].coverIsSquare)
        // A fetch that found only portrait art taught the list so; a rebuild keeps it.
        var learnt = first
        learnt[0].coverIsSquare = false
        #expect(!OtherBook.selection(from: books, excluding: nil, existing: learnt)[0].coverIsSquare)
    }

    // MARK: - When a change is worth writing

    @Test("the same list is not worth a write; a new order, id or title is")
    func identityRule() {
        let a = OtherBook(bookID: "a", title: "A", progress: 0.1)
        let b = OtherBook(bookID: "b", title: "B", progress: 0.2)
        #expect(!OtherBook.worthWriting(old: [a, b], next: [a, b]))
        #expect(OtherBook.worthWriting(old: [a, b], next: [b, a]))
        #expect(OtherBook.worthWriting(old: [a, b], next: [a]))
        #expect(OtherBook.worthWriting(old: [a], next: [a, b]))
        #expect(OtherBook.worthWriting(old: [], next: [a]))
        #expect(!OtherBook.worthWriting(old: [], next: []))
        var renamed = a
        renamed.title = "A, revised"
        #expect(OtherBook.worthWriting(old: [a], next: [renamed]))
    }

    @Test("progress is worth a write at a fifth of a percent, not before")
    func progressRule() {
        let a = OtherBook(bookID: "a", title: "A", progress: 0.100)
        var near = a
        near.progress = 0.1015
        var moved = a
        moved.progress = 0.1021
        #expect(!OtherBook.worthWriting(old: [a], next: [near]))
        #expect(OtherBook.worthWriting(old: [a], next: [moved]))
        // The cover shape alone is the cover fetch's own write, not this rule's.
        var squared = a
        squared.coverIsSquare = true
        #expect(!OtherBook.worthWriting(old: [a], next: [squared]))
    }

    // MARK: - Decoding what 1.6.x wrote

    @Test("a snapshot written before the list existed decodes to none")
    func oldFileHasNoOthers() throws {
        let json = #"{"bookID":"u","title":"T","author":"A","progress":0.5,"coverIsSquare":true}"#
        let restored = try JSONDecoder().decode(CurrentBookSnapshot.self, from: Data(json.utf8))
        #expect(restored.others.isEmpty)
        #expect(restored.title == "T")
    }

    @Test("the list round-trips, and a bad entry costs the list, not the book")
    func roundTripAndForgiveness() throws {
        let others = [
            OtherBook(bookID: "a", title: "A", author: "X", progress: 0.3, coverIsSquare: true),
            OtherBook(bookID: "b", title: "B", progress: 0.9),
        ]
        let original = CurrentBookSnapshot(bookID: "u", title: "T", author: "A", progress: 0.5, others: others)
        let restored = try JSONDecoder().decode(
            CurrentBookSnapshot.self, from: JSONEncoder().encode(original))
        #expect(restored.others == others)

        let broken = #"{"bookID":"u","title":"T","author":"A","progress":0.5,"others":[{"nonsense":1}]}"#
        let tolerant = try JSONDecoder().decode(CurrentBookSnapshot.self, from: Data(broken.utf8))
        #expect(tolerant.others.isEmpty)
        #expect(tolerant.title == "T")
    }
}

/// The files. A directory stands in for the App Group, which `swift test` has
/// no entitlement to; serialised because that stand-in is one global.
@Suite("The other books' cover files", .serialized)
struct OtherCoverStoreTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-widget-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CurrentBookSnapshotStore.directoryOverride = directory
        defer {
            CurrentBookSnapshotStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory)
    }

    @Test("each cover is its own file, named by its book")
    func roundTrip() throws {
        try withDirectory { _ in
            CurrentBookSnapshotStore.writeOtherCover(Data("one".utf8), bookID: "aaa")
            CurrentBookSnapshotStore.writeOtherCover(Data("two".utf8), bookID: "bbb")
            #expect(CurrentBookSnapshotStore.readOtherCover(bookID: "aaa") == Data("one".utf8))
            #expect(CurrentBookSnapshotStore.readOtherCover(bookID: "bbb") == Data("two".utf8))
            #expect(CurrentBookSnapshotStore.readOtherCover(bookID: "ccc") == nil)
            #expect(CurrentBookSnapshotStore.hasOtherCover(bookID: "aaa"))
            #expect(!CurrentBookSnapshotStore.hasOtherCover(bookID: "ccc"))
        }
    }

    @Test("a book that left the list loses its file; the rest, and the current cover, stay")
    func pruning() throws {
        try withDirectory { _ in
            CurrentBookSnapshotStore.writeCover(Data("current".utf8))
            CurrentBookSnapshotStore.write(CurrentBookSnapshot(bookID: "u", title: "T", author: "A", progress: 0))
            for id in ["a", "b", "c"] { CurrentBookSnapshotStore.writeOtherCover(Data(id.utf8), bookID: id) }
            CurrentBookSnapshotStore.pruneOtherCovers(keeping: ["a", "c"])
            #expect(CurrentBookSnapshotStore.hasOtherCover(bookID: "a"))
            #expect(!CurrentBookSnapshotStore.hasOtherCover(bookID: "b"))
            #expect(CurrentBookSnapshotStore.hasOtherCover(bookID: "c"))
            #expect(CurrentBookSnapshotStore.readCover() == Data("current".utf8))
            #expect(CurrentBookSnapshotStore.read() != nil)
        }
    }

    @Test("signing out removes them all, with the snapshot and the current cover")
    func clearRemovesEverything() throws {
        try withDirectory { directory in
            CurrentBookSnapshotStore.write(CurrentBookSnapshot(bookID: "u", title: "T", author: "A", progress: 0))
            CurrentBookSnapshotStore.writeCover(Data("current".utf8))
            for id in ["a", "b"] { CurrentBookSnapshotStore.writeOtherCover(Data(id.utf8), bookID: id) }
            CurrentBookSnapshotStore.clear()
            let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(left.isEmpty)
        }
    }

    @Test("an id that would name a path is not a file")
    func pathsAreRefused() throws {
        try withDirectory { _ in
            CurrentBookSnapshotStore.writeOtherCover(Data("x".utf8), bookID: "../escape")
            #expect(CurrentBookSnapshotStore.readOtherCover(bookID: "../escape") == nil)
            #expect(CurrentBookSnapshotStore.otherCoverURL(bookID: "") == nil)
        }
    }
}
