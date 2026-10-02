import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// What a book's menu asks of the model, and what the book page decides from
/// the catalogue for its tag chips.
@Suite("Book menu actions", .serialized)
@MainActor
struct BookActionsTests {
    private func model(_ books: [Book]) -> AppModel {
        DerivedCatalogueTests.model(books)
    }

    /// The menu's Read pushes the book page and arms this, so the page opens
    /// the reader as it appears — once, as a deep link's request is.
    @Test("Read arms the page's reader for a book with text, once")
    func readerRequestIsOneShot() {
        let dracula = SharedFixtures.book("Dracula", uuid: "d")
        let app = model([dracula])

        #expect(app.requestReader(for: dracula))
        #expect(app.consumeReaderRequest(for: dracula), "the page did not open the reader")
        #expect(!app.consumeReaderRequest(for: dracula),
                "a later visit to the page reopened the reader unasked")
    }

    @Test("a book with no text arms nothing, and its page is where Read goes")
    func audiobookArmsNothing() {
        let audio = SharedFixtures.book("Carmilla", uuid: "c", audiobook: true, ebook: false)
        let app = model([audio])

        #expect(!app.requestReader(for: audio))
        #expect(!app.consumeReaderRequest(for: audio))
    }

    @Test("the request is for one book: another book's page does not take it")
    func requestIsPerBook() {
        let dracula = SharedFixtures.book("Dracula", uuid: "d")
        let other = SharedFixtures.book("Carmilla", uuid: "c")
        let app = model([dracula, other])

        app.requestReader(for: dracula)
        #expect(!app.consumeReaderRequest(for: other))
        #expect(app.consumeReaderRequest(for: dracula))
    }

    /// A request left armed by one account must not open a reader in the
    /// next: the server hands the same book uuids to a different reader.
    @Test("signing out clears an armed request")
    func signOutClearsTheRequest() async {
        let dracula = SharedFixtures.book("Dracula", uuid: "d")
        let app = model([dracula])

        app.requestReader(for: dracula)
        await app.signOut(keepDownloads: true)
        #expect(!app.consumeReaderRequest(for: dracula))
    }

    // MARK: - Tag chips

    @Test("a chip links only for a tag on two books or more, counted once each")
    func chipsLinkAtTwoBooks() {
        let app = model([
            SharedFixtures.book("Dracula", uuid: "d", tags: ["Gothic", "Epistolary", "Epistolary"]),
            SharedFixtures.book("Carmilla", uuid: "c", tags: ["Gothic"]),
        ])
        #expect(BookDetailView.isLinked("Gothic", booksByTag: app.booksByTag))
        // On one book, however many times that book lists it.
        #expect(!BookDetailView.isLinked("Epistolary", booksByTag: app.booksByTag))
        #expect(!BookDetailView.isLinked("Absent", booksByTag: app.booksByTag))
    }

    @Test("the identifier goes on the first linked chip, not the first chip")
    func identifierOnTheFirstLink() throws {
        let dracula = SharedFixtures.book("Dracula", uuid: "d", tags: ["Epistolary", "Gothic", "Horror"])
        let app = model([
            dracula,
            SharedFixtures.book("Carmilla", uuid: "c", tags: ["Gothic", "Horror"]),
        ])
        let first = try #require(BookDetailView.firstLinkedTagID(dracula.distinctTags, booksByTag: app.booksByTag))
        #expect(dracula.distinctTags.first { $0.id == first }?.name == "Gothic")
    }
}
