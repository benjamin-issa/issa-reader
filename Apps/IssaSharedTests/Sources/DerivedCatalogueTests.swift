import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// The memoised catalogue indexes stay as live as the scans they replaced.
///
/// `BookDetailView` re-resolves its book from the model on every one of the 52
/// lines that reads it, deliberately: a value handed in at navigation time does
/// not change when the library does, so the screen would show a stale status,
/// rating and position. That re-resolution was a linear scan of the whole
/// library, and the body it sits in re-runs on every debounced position save —
/// every two seconds while the book is narrating. It is a dictionary lookup
/// now, and the entire risk of that change is the dictionary going stale on a
/// path that used to be covered for free. Each case below is one such path.
@Suite("Derived catalogue indexes", .serialized)
@MainActor
struct DerivedCatalogueTests {
    static func model(_ books: [Book]) -> AppModel {
        let app = AppModel(notificationCentre: NotificationCenter())
        app.books = books
        app.rebuildDerived()
        return app
    }

    @Test("the index holds every book the catalogue does")
    func indexesTheCatalogue() {
        let app = Self.model([
            SharedFixtures.book("Dracula", uuid: "d"),
            SharedFixtures.book("Bleak House", uuid: "b"),
        ])
        #expect(app.bookByUUID["d"]?.title == "Dracula")
        #expect(app.bookByUUID["b"]?.title == "Bleak House")
        #expect(app.bookByUUID["missing"] == nil)
    }

    /// The path that matters. `recordPosition` mutates one element and calls
    /// the position-only rebuild — the cheap one, which exists precisely
    /// because it runs every two seconds. An index rebuilt only alongside the
    /// facets would have gone stale here, and the book screen would have shown
    /// the position the reader was at when they opened it, for as long as they
    /// left it open.
    @Test("a position write reaches the index")
    func positionWritesAreVisible() async {
        let app = Self.model([SharedFixtures.book("Dracula", uuid: "d", progress: 0.1)])
        let before = app.bookByUUID["d"]?.position?.locator.totalProgression
        #expect(before.map { abs($0 - 0.1) < 0.0001 } == true)

        await app.recordPosition(
            ReadiumLocator(href: "OEBPS/ch09.xhtml", type: "application/xhtml+xml",
                           locations: .init(progression: 0.62, totalProgression: 0.62)),
            timestamp: 1,
            for: "d",
        )

        let after = app.bookByUUID["d"]?.position?.locator.totalProgression
        #expect(after.map { abs($0 - 0.62) < 0.0001 } == true,
                "the book screen would still be showing \(String(describing: after))")
    }

    /// A book with no status — which 3.x sends for a book nobody has filed —
    /// is shelved by its position, so the first position written for it moves
    /// it from To read to Reading. `recordPosition` ran only the position-only
    /// rebuild, on the premise that a page turn cannot change a shelf: the grid
    /// moved the book while the chips went on counting it under To read and
    /// the Reading tab went on listing it under Up next, beside the Continue
    /// card it had just become. Where the rule then files it the full rebuild
    /// runs anyway; where it does not — no permission to write a status, or no
    /// status known to write — that was the state until the next refresh.
    @Test("a position that moves an unfiled book to another shelf moves its counts and rails")
    func aPositionThatChangesTheShelfRebuildsTheFacets() async {
        let app = Self.model([
            SharedFixtures.book("Dracula", uuid: "d"),
            SharedFixtures.book("Bleak House", uuid: "b"),
        ])
        #expect(app.facets.count(.toRead) == 2)
        #expect(app.facets.count(.reading) == 0)
        #expect(app.readingHome.upNext.contains { $0.uuid == "d" })

        await app.recordPosition(
            ReadiumLocator(href: "OEBPS/ch09.xhtml", type: "application/xhtml+xml",
                           locations: .init(progression: 0.5, totalProgression: 0.5)),
            timestamp: 1,
            for: "d",
        )

        #expect(app.arrangedBooks.contains { $0.uuid == "d" }, "the grid is not what is under test")
        #expect(app.facets.count(.reading) == 1, "the Reading chip did not count the book now on it")
        #expect(app.facets.count(.toRead) == 1, "the To read chip went on counting a book being read")
        #expect(app.rails.reading.contains { $0.uuid == "d" })
        #expect(!app.rails.toRead.contains { $0.uuid == "d" })
        #expect(!app.readingHome.upNext.contains { $0.uuid == "d" },
                "Up next listed the book beside the Continue card it had become")
    }

    /// Signing out empties the catalogue, and an index that survived it would
    /// hand the next account a book from the previous one — the same class of
    /// leak the sign-out widening closed for `pendingBook` and the ratings.
    ///
    /// Keeping the downloads: the download directory is the host app's real
    /// one, and nothing here is about the files.
    @Test("signing out empties the index too")
    func signOutClearsTheIndex() async {
        let app = Self.model([SharedFixtures.book("Dracula", uuid: "d")])
        #expect(app.bookByUUID["d"] != nil)
        await app.signOut(keepDownloads: true)
        #expect(app.bookByUUID.isEmpty)
    }

    /// `byAuthor` and `byNarrator` group the entire library, and `relatedRails`
    /// read one of each — from a view body. Memoised now; the grouping itself
    /// has to be unchanged.
    @Test("the author and narrator groupings say what the computed ones did")
    func groupingsMatchTheDerivation() {
        let books = [
            SharedFixtures.book("Dracula", uuid: "d", authors: ["Bram Stoker"], narrators: ["A Reader"]),
            SharedFixtures.book("The Lair", uuid: "l", authors: ["Bram Stoker"]),
            SharedFixtures.book("Bleak House", uuid: "b", authors: ["Charles Dickens"]),
        ]
        let app = Self.model(books)
        let derivation = LibraryDerivation(books: books)

        #expect(app.booksByAuthor.mapValues { $0.map(\.uuid) }
            == derivation.byAuthor.mapValues { $0.map(\.uuid) })
        #expect(app.booksByNarrator.mapValues { $0.map(\.uuid) }
            == derivation.byNarrator.mapValues { $0.map(\.uuid) })
        #expect(app.booksByAuthor["Bram Stoker"]?.count == 2)
        #expect(app.booksByNarrator["A Reader"]?.count == 1)
    }
}
