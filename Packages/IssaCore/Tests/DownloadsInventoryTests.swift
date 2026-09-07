import Foundation
import Testing

@testable import IssaCore

/// What the downloads screens are drawing, without a screen.
///
/// The grouping and the arithmetic used to live inside `DownloadsView`, a
/// SwiftUI file no test target in this repo can reach — which is how the
/// storage bar came to disagree with its own headline for a whole release and
/// nothing said so. `make(books:downloaded:sizes:)` is handed its sizes rather
/// than reading them, so every rule below is checked against a literal.
@Suite("What is on this device")
struct DownloadsInventoryTests {
    /// Built by decoding, like every other `Book` in this repo: there is no
    /// public initialiser, and inventing one for tests would be a second
    /// definition of what a book is.
    private func book(_ uuid: String, title: String, author: String = "") -> Book {
        var json: [String: Any] = [
            "uuid": uuid, "title": title,
            "authors": author.isEmpty ? [] : [["uuid": author, "name": author]],
            "narrators": [], "creators": [], "series": [],
            "collections": [], "identifiers": [], "tags": [],
        ]
        json["ebook"] = ["uuid": "e", "filepath": "e.epub", "identifiers": []]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    private func key(_ uuid: String, _ format: BookContentService.Format)
        -> DownloadsInventory.FileKey {
        DownloadsInventory.FileKey(bookUUID: uuid, format: format)
    }

    // MARK: - Grouping

    @Test("a book with two editions on the device is two rows, and one book")
    func twoEditionsAreTwoRowsAndOneBook() {
        let dracula = book("d", title: "Dracula", author: "Bram Stoker")
        let inventory = DownloadsInventory.make(
            books: [dracula], downloaded: ["d"],
            sizes: .init(
                files: [key("d", .readaloud): 600, key("d", .ebook): 40],
                booksDirectoryBytes: 640),
        )

        #expect(inventory.items.count == 2)
        #expect(inventory.bookCount == 1, "a reader counts books, not files")
        #expect(inventory.itemBytes == 640)
        #expect(Set(inventory.items.map(\.format)) == [.readaloud, .ebook])
    }

    @Test("a book with no file on this device has no row")
    func aBookWithNoFileHasNoRow() {
        let inventory = DownloadsInventory.make(
            books: [book("d", title: "Dracula"), book("f", title: "Frankenstein")],
            downloaded: ["d"],
            sizes: .init(files: [key("d", .ebook): 10], booksDirectoryBytes: 10),
        )

        #expect(inventory.items.map(\.book.uuid) == ["d"])
    }

    /// The bound that keeps the loop off the whole library: `isDownloaded` is a
    /// `stat` per book per format, so a catalogue of a thousand books whose
    /// owner has kept three must cost three lookups rather than three thousand.
    /// A file whose uuid is not in the downloaded set is not consulted at all.
    @Test("the downloaded set bounds the work, not the catalogue")
    func theDownloadedSetBoundsTheScan() {
        let inventory = DownloadsInventory.make(
            books: [book("d", title: "Dracula")],
            downloaded: [],
            sizes: .init(files: [key("d", .ebook): 10], booksDirectoryBytes: 10),
        )

        #expect(inventory.items.isEmpty)
    }

    // MARK: - Order

    @Test("the rows are largest first, because the question is what is taking the room")
    func rowsAreLargestFirst() {
        let inventory = DownloadsInventory.make(
            books: [
                book("small", title: "A"), book("large", title: "B"), book("middle", title: "C"),
            ],
            downloaded: ["small", "large", "middle"],
            sizes: .init(
                files: [
                    key("small", .ebook): 10,
                    key("large", .ebook): 900,
                    key("middle", .ebook): 200,
                ],
                booksDirectoryBytes: 1110),
        )

        #expect(inventory.items.map(\.book.uuid) == ["large", "middle", "small"])
    }

    /// Two rows the same size must not shuffle between refreshes: a list that
    /// reorders itself on every scan is a list that flickers for no reason.
    @Test("rows of equal size keep a stable order")
    func equalSizesAreOrderedStably() {
        let sizes = DownloadsInventory.Sizes(
            files: [key("b", .ebook): 100, key("a", .ebook): 100], booksDirectoryBytes: 200)
        let first = DownloadsInventory.make(
            books: [book("b", title: "Beta"), book("a", title: "Alpha")],
            downloaded: ["a", "b"], sizes: sizes)
        let second = DownloadsInventory.make(
            books: [book("a", title: "Alpha"), book("b", title: "Beta")],
            downloaded: ["a", "b"], sizes: sizes)

        #expect(first.items.map(\.id) == second.items.map(\.id))
        #expect(first.items.map(\.book.title) == ["Alpha", "Beta"])
    }

    // MARK: - Per-format totals

    @Test("each format's band is the sum of its own files")
    func perFormatTotals() {
        let inventory = DownloadsInventory.make(
            books: [book("a", title: "A"), book("b", title: "B")],
            downloaded: ["a", "b"],
            sizes: .init(
                files: [
                    key("a", .readaloud): 600,
                    key("b", .readaloud): 300,
                    key("a", .ebook): 40,
                ],
                booksDirectoryBytes: 940),
        )

        #expect(inventory.byFormat[.readaloud] == 900)
        #expect(inventory.byFormat[.ebook] == 40)
        #expect(inventory.byFormat[.audiobook] == nil, "a band with nothing in it is not drawn")
    }

    // MARK: - The bytes with no row

    /// The bug the whole type exists for: the headline counted the Books
    /// directory, the bands counted books still in the catalogue, and the
    /// difference had no row — so it could never be deleted from the interface.
    @Test("a download whose book has left the library is counted, not hidden")
    func unaccountedBytesSurfaceADepartedBook() {
        let inventory = DownloadsInventory.make(
            books: [book("kept", title: "Kept")],
            downloaded: ["kept", "gone"],
            sizes: .init(
                files: [key("kept", .ebook): 100, key("gone", .readaloud): 500],
                booksDirectoryBytes: 600),
        )

        #expect(inventory.itemBytes == 100)
        #expect(inventory.unaccountedBytes == 500)
        #expect(inventory.bookFileBytes == 600, "the headline still counts the whole directory")
        #expect(inventory.orphans == [DownloadsInventory.FileKey(bookUUID: "gone", format: .readaloud)])
    }

    @Test("a file the app did not name is counted but never offered for deletion")
    func junkIsCountedButNotSwept() {
        let inventory = DownloadsInventory.make(
            books: [book("kept", title: "Kept")], downloaded: ["kept"],
            sizes: .init(
                files: [key("kept", .ebook): 100],
                // 100 of book plus 20 of something else entirely.
                booksDirectoryBytes: 120),
        )

        #expect(inventory.unaccountedBytes == 20)
        #expect(inventory.orphans.isEmpty, "a sweep only touches files this app named")
    }

    @Test("everything adds up: rows plus the unaccounted is the directory")
    func theBarAddsUpToTheHeadline() {
        let inventory = DownloadsInventory.make(
            books: [book("kept", title: "Kept")], downloaded: ["kept", "gone"],
            sizes: .init(
                files: [key("kept", .ebook): 100, key("gone", .ebook): 400],
                booksDirectoryBytes: 500,
                extractedAudioBytes: 30, coverBytes: 20, publisherFontBytes: 10),
        )

        let bands = inventory.byFormat.values.reduce(0, +)
            + inventory.unaccountedBytes
            + inventory.extractedAudioBytes
            + inventory.coverBytes
            + inventory.publisherFontBytes
        #expect(bands == inventory.totalBytes)
    }

    /// Two reads of a directory a background transfer wrote to in between can
    /// disagree; a negative band would draw the bar going the wrong way.
    @Test("a directory total behind the rows never yields a negative band")
    func unaccountedNeverGoesNegative() {
        let inventory = DownloadsInventory.make(
            books: [book("a", title: "A")], downloaded: ["a"],
            sizes: .init(files: [key("a", .ebook): 500], booksDirectoryBytes: 100),
        )

        #expect(inventory.unaccountedBytes == 0)
    }

    // MARK: - The reconciliation diff

    /// What the sweep asks after every re-read of the disk.
    @Test("a book whose last file went has departed")
    func aBookThatLostItsLastFileHasDeparted() {
        #expect(DownloadsInventory.departed(from: ["a", "b"], to: ["a"]) == ["b"])
    }

    /// The case that makes it a set question rather than a file question:
    /// removing one of two editions must not take the book's index, its
    /// extracted narration and its publisher font with it.
    @Test("a book that still has one edition on the device has not departed")
    func aBookWithAnotherEditionHasNotDeparted() {
        #expect(DownloadsInventory.departed(from: ["a"], to: ["a"]).isEmpty)
    }

    @Test("a book that arrived is not a book that left")
    func anArrivalIsNotADeparture() {
        #expect(DownloadsInventory.departed(from: ["a"], to: ["a", "b"]).isEmpty)
    }

    // MARK: - The reader-facing name

    /// The app says "Read-along" and the server says "Readaloud", and the
    /// Downloads screen was printing the server's spelling in two places
    /// because the app's was a private function on the book screen.
    @Test("an edition is named the way the app names it, never the way the server does")
    func formatDisplayNames() {
        #expect(BookContentService.Format.readaloud.displayName == "Read-along")
        #expect(BookContentService.Format.ebook.displayName == "Ebook")
        #expect(BookContentService.Format.audiobook.displayName == "Audiobook")
        for format in BookContentService.Format.allCases {
            #expect(
                format.displayName.lowercased() != "readaloud",
                "the server's spelling must not reach a reader")
        }
    }

    // MARK: - Naming a file both ways

    @Test("a download's filename decodes back to the book and the edition it came from")
    func filenamesRoundTrip() throws {
        let directory = URL(fileURLWithPath: "/tmp/books")
        for format in BookContentService.Format.allCases {
            let url = BookContentService.localURL(
                in: directory, bookUUID: "11111111-1111-4111-8111-111111111111", format: format)
            let decoded = try #require(BookContentService.decodeFilename(url.lastPathComponent))
            #expect(decoded.bookUUID == "11111111-1111-4111-8111-111111111111")
            #expect(decoded.format == format)
        }
    }

    @Test("a file this app did not write is not claimed as a download")
    func foreignFilenamesAreNotClaimed() {
        #expect(BookContentService.decodeFilename("something.txt") == nil)
        #expect(BookContentService.decodeFilename("-ebook.epub") == nil)
        #expect(BookContentService.decodeFilename("a-unknown.epub") == nil)
    }

    // MARK: - The disk half

    @Test("the scan reads one directory and finds both the sizes and the total")
    func scanReadsTheDirectoryOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "issa-inventory-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let uuid = "11111111-1111-4111-8111-111111111111"
        try Data(repeating: 0, count: 300).write(
            to: BookContentService.localURL(in: directory, bookUUID: uuid, format: .ebook))
        // Something the app did not write, so the total exceeds the rows.
        try Data(repeating: 0, count: 25).write(to: directory.appending(path: "stray.tmp"))

        let inventory = await DownloadsInventory.scan(
            books: [book(uuid, title: "Alice")], downloaded: [uuid],
            scope: .booksOnly, booksDirectory: directory)

        #expect(inventory.items.count == 1)
        #expect(inventory.items.first?.bytes == 300)
        #expect(inventory.bookFileBytes == 325)
        #expect(inventory.unaccountedBytes == 25)
        // The cheap scope is the Reading tab's: no recursive walks at all.
        #expect(inventory.extractedAudioBytes == 0)
        #expect(inventory.coverBytes == 0)
        #expect(inventory.publisherFontBytes == 0)
    }

    /// `Fonts/` holds two kinds of file at two depths, and only one of them
    /// came out of a download.
    @Test("only the per-book subdirectories of a font folder are sized")
    func onlyExtractedFacesAreSized() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "issa-fonts-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = root.appending(path: "book-uuid", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The reader's own import, at the root.
        try Data(repeating: 0, count: 1000).write(to: root.appending(path: "Imported.otf"))
        // A publisher's face, under the book it came out of.
        try Data(repeating: 0, count: 40).write(to: extracted.appending(path: "body.otf"))

        #expect(DownloadsInventory.subdirectorySize(root) == 40)
        #expect(DownloadsInventory.directorySize(root) == 1040, "the whole tree, for comparison")
    }
}
