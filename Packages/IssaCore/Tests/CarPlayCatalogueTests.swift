import Foundation
import Testing

@testable import IssaCore

/// What a car is offered.
///
/// Every rule here is one that is wrong in a way you would only discover while
/// driving, which is the whole reason it lives in a package rather than in the
/// scene delegate: the app targets have no test target at all.
@Suite("The CarPlay catalogue")
struct CarPlayCatalogueTests {
    /// Built by decoding, the same way a real book arrives — the model has no
    /// public initialiser, and inventing one for tests would be a second
    /// definition of what a book is.
    func book(
        _ title: String, author: String = "Someone",
        progress: Double? = nil, positionTimestamp: Double? = nil,
        audioDuration: Double? = nil, narrated: Bool = false,
        ebookOnly: Bool = false, audioMissing: Bool = false,
    ) -> Book {
        var json: [String: Any] = [
            "uuid": title, "title": title,
            "authors": [["uuid": author, "name": author, "fileAs": author]],
            "narrators": [], "creators": [], "series": [], "collections": [],
            "identifiers": [], "tags": [],
        ]
        if let progress {
            json["position"] = [
                "locator": ["href": "a", "type": "t",
                            "locations": ["totalProgression": progress]],
                "timestamp": positionTimestamp ?? 0,
            ]
        }
        if ebookOnly {
            json["ebook"] = ["uuid": "e", "filepath": "book.epub", "identifiers": []]
        } else if narrated {
            var readaloud: [String: Any] = ["uuid": "r", "filepath": "r.epub", "identifiers": []]
            if let audioDuration { readaloud["duration"] = audioDuration }
            if audioMissing { readaloud["missing"] = true }
            json["readaloud"] = readaloud
        } else {
            var audiobook: [String: Any] = ["uuid": "a", "filepath": "a.m4b", "identifiers": []]
            if let audioDuration { audiobook["duration"] = audioDuration }
            if audioMissing { audiobook["missing"] = true }
            json["audiobook"] = audiobook
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    static let plenty = 100

    // MARK: - What may be offered at all

    @Test("a book with no audio is never listed")
    func textOnlyBooksAreExcluded() {
        // Offering one is offering the driver a button that does nothing, and
        // they will press it at speed to find out.
        let catalogue = CarPlayCatalogue(books: [
            book("Silent", ebookOnly: true),
            book("Spoken"),
        ])
        let titles = catalogue.entries(for: .library, limit: Self.plenty).map(\.title)
        #expect(titles == ["Spoken"])
    }

    @Test("a format the server cannot actually serve is not offered either")
    func missingAudioIsExcluded() {
        // The server creates a readaloud row when alignment is merely
        // requested, so a bare nil check promises narration that is not there.
        let catalogue = CarPlayCatalogue(books: [
            book("Requested", narrated: true, audioMissing: true),
            book("Aligned", narrated: true),
        ])
        let titles = catalogue.entries(for: .library, limit: Self.plenty).map(\.title)
        #expect(titles == ["Aligned"])
    }

    // MARK: - The head unit's limits

    @Test("a long list is cut to what the head unit will draw")
    func respectsTheLimit() {
        let books = (1 ... 40).map { book("Book \($0)") }
        let catalogue = CarPlayCatalogue(books: books)
        #expect(catalogue.entries(for: .library, limit: 12).count == 12)
        // CarPlay enforces its maximum rather than advising it, and the bridge
        // used to hand it fifty.
        #expect(catalogue.entries(for: .library, limit: 12).first?.title == "Book 1")
    }

    @Test("a nonsensical limit yields nothing rather than trapping")
    func nonPositiveLimit() {
        let catalogue = CarPlayCatalogue(books: [book("One")])
        #expect(catalogue.entries(for: .library, limit: 0).isEmpty)
        #expect(catalogue.entries(for: .library, limit: -3).isEmpty)
    }

    // MARK: - Order

    @Test("Recent is what was most recently in progress, newest first")
    func recentOrdersByPositionTimestamp() {
        let catalogue = CarPlayCatalogue(books: [
            book("Older", progress: 0.4, positionTimestamp: 100),
            book("Newest", progress: 0.2, positionTimestamp: 900),
            book("Untouched"),
        ])
        let titles = catalogue.entries(for: .recent, limit: Self.plenty).map(\.title)
        #expect(titles == ["Newest", "Older"])
    }

    @Test("Downloaded holds only what will play with no signal")
    func downloadedShelf() {
        let catalogue = CarPlayCatalogue(
            books: [
                book("OnDevice", progress: 0.5, positionTimestamp: 10),
                book("Streamed", progress: 0.5, positionTimestamp: 20),
            ],
            downloadedUUIDs: ["OnDevice"],
        )
        let entries = catalogue.entries(for: .downloaded, limit: Self.plenty)
        #expect(entries.map(\.title) == ["OnDevice"])
        #expect(entries.first?.isDownloaded == true)
    }

    /// The bug this pins: the shelf used `.continueReading`, which drops any
    /// book without progress — so an audiobook downloaded for the drive and
    /// never yet opened was answered with "No downloads on this phone".
    @Test("a download never opened still shows on the Downloaded shelf")
    func downloadedShelfIncludesUnstartedBooks() {
        let catalogue = CarPlayCatalogue(
            books: [
                book("FreshDownload"),
                book("HalfDone", progress: 0.5, positionTimestamp: 10),
                book("Streamed", progress: 0.5, positionTimestamp: 20),
            ],
            downloadedUUIDs: ["FreshDownload", "HalfDone"],
        )
        let titles = catalogue.entries(for: .downloaded, limit: Self.plenty).map(\.title)
        // In progress first, most recent on top; unstarted downloads follow.
        #expect(titles == ["HalfDone", "FreshDownload"])
    }

    @Test("a download does not jump the queue on the other shelves")
    func downloadsDoNotReorderRecent() {
        // A driver looking for the book they were in the middle of should find
        // it where they left it. Offline availability is a shelf of its own, not
        // a re-sort of every other one.
        let catalogue = CarPlayCatalogue(
            books: [
                book("Streamed", progress: 0.5, positionTimestamp: 900),
                book("OnDevice", progress: 0.5, positionTimestamp: 100),
            ],
            downloadedUUIDs: ["OnDevice"],
        )
        #expect(catalogue.entries(for: .recent, limit: Self.plenty).map(\.title)
            == ["Streamed", "OnDevice"])
    }

    // MARK: - What a row says

    @Test("a row says who wrote it and how much is left")
    func subtitleIsGlanceable() {
        let catalogue = CarPlayCatalogue(books: [
            book("Novel", author: "Sanderson", progress: 0.5, audioDuration: 7200),
        ])
        let entry = catalogue.entries(for: .library, limit: Self.plenty).first
        #expect(entry?.subtitle == "Sanderson · 1h 0m left")
    }

    @Test("a book never started says its whole length")
    func subtitleWithoutProgress() {
        let catalogue = CarPlayCatalogue(books: [
            book("Novel", author: "Sanderson", audioDuration: 5400),
        ])
        #expect(catalogue.entries(for: .library, limit: Self.plenty).first?.subtitle
            == "Sanderson · 1h 30m left")
    }

    @Test("a book with no known duration still says who wrote it")
    func subtitleWithoutDuration() {
        let catalogue = CarPlayCatalogue(books: [book("Novel", author: "Sanderson")])
        #expect(catalogue.entries(for: .library, limit: Self.plenty).first?.subtitle == "Sanderson")
    }

    @Test("a finished book does not report a negative remainder")
    func finishedBookRemainder() {
        let catalogue = CarPlayCatalogue(books: [
            book("Done", author: "A", progress: 1.0, positionTimestamp: 1, audioDuration: 3600),
        ])
        #expect(catalogue.entries(for: .recent, limit: Self.plenty).first?.subtitle == "A · 0m left")
    }

    @Test("durations read the way a driver would say them",
          arguments: [(0.0, "0m"), (59.0, "0m"), (90.0, "1m"), (3600.0, "1h 0m"),
                      (5430.0, "1h 30m"), (98_100.0, "27h 15m")])
    func durationText(_ seconds: Double, _ expected: String) {
        #expect(CarPlayCatalogue.durationText(seconds) == expected)
    }

    @Test("a nonsense duration does not become a nonsense label")
    func durationTextGuards() {
        #expect(CarPlayCatalogue.durationText(.nan) == "0m")
        #expect(CarPlayCatalogue.durationText(-100) == "0m")
        #expect(CarPlayCatalogue.durationText(.infinity) == "0m")
    }

    // MARK: - Empty

    @Test("every shelf has something to say when it is empty",
          arguments: CarPlayCatalogue.Shelf.allCases)
    func emptyMessages(_ shelf: CarPlayCatalogue.Shelf) {
        // A blank list in a car is indistinguishable from an app that crashed.
        #expect(!shelf.emptyMessage.isEmpty)
        #expect(!shelf.title.isEmpty)
        #expect(CarPlayCatalogue(books: []).entries(for: shelf, limit: Self.plenty).isEmpty)
    }
}
