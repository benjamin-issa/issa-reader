import Foundation
import IssaCore
import SwiftUI
import Testing
import UIKit

@testable import IssaReader_iOS

/// Where a book's menu, a page's "Show in Library" and the Reading screen's
/// links take the reader, and what a deep link leaves standing.
@Suite("Book routes", .serialized)
@MainActor
struct BookRoutingTests {
    // MARK: - R-21

    /// A deep link to the book whose reader is up is discarded by the tab's
    /// root; the screen's router took its pushed page — and the reader on it
    /// — down all the same.
    @Test("a link to the book being read leaves the page its reader is on")
    func linkToTheOpenBookKeepsThePushedPage() {
        #expect(!BookRouter.dropsPushedPage(for: "dracula", visibleReader: "dracula"))
        #expect(BookRouter.dropsPushedPage(for: "dracula", visibleReader: "emma"))
        #expect(BookRouter.dropsPushedPage(for: "dracula", visibleReader: nil))
        #expect(!BookRouter.dropsPushedPage(for: nil, visibleReader: nil))
    }

    // MARK: - R-20

    /// One navigator for the process sent an author page's search to
    /// whichever window's library appeared first, and reset every window.
    @Test("a Show in Library search goes to the window that asked, through its own navigator")
    func searchGoesToItsOwnWindow() async throws {
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        app.phase = .ready
        let asking = LibraryNavigator()
        let other = LibraryNavigator()
        asking.showLibrary(search: "Austen")

        func library(_ navigator: LibraryNavigator) -> some View {
            NavigationStack { LibraryView() }
                .environment(app)
                .environment(AppServices.shared.settings)
                .environment(AppServices.shared.nowPlaying)
                .environment(navigator)
        }
        // The other window's library appears first, as it could.
        let second = try RootWindowTests.Window(library(other))
        defer { second.close() }
        try await Task.sleep(for: .milliseconds(300))
        let first = try RootWindowTests.Window(library(asking))
        defer { first.close() }

        let taken = await LocalImportTests.eventually(within: .seconds(5)) { asking.pendingSearch == nil }
        #expect(taken, "the asking window's library never took its search")
        #expect(asking.showRequests == 1)
        #expect(other.showRequests == 0, "another window was asked to show its library")
        #expect(other.pendingSearch == nil)
    }

    // MARK: - The Reading screen's links (Browse side note)

    @Test("a See all lands on that shelf's grid; Go to Library on the Browse rails")
    func readingLinks() {
        let seeAll = LibraryModeSwitch.fromReading(.toRead)
        #expect(seeAll == .init(mode: .all, shelf: .toRead, isSearching: false))
        #expect(!LibraryModeSwitch.showsRails(seeAll))

        let downloaded = LibraryModeSwitch.fromReading(.downloaded)
        #expect(downloaded == .init(mode: .all, shelf: .downloaded, isSearching: false))

        let landing = LibraryModeSwitch.fromReading(nil)
        #expect(landing == .init(mode: .browse, shelf: .all, isSearching: false))
        #expect(LibraryModeSwitch.showsRails(landing))
    }

    /// The app's state after each link, from wherever the library was left.
    @Test("the links set the library's mode, whatever it was left on")
    func readingLinksSetTheMode() {
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        let (mode, arrangement) = (app.libraryMode, app.arrangement)
        defer {
            app.libraryMode = mode
            app.arrangement = arrangement
        }

        app.libraryMode = .browse
        app.showLibrary(fromReading: .toRead)
        #expect(app.libraryMode == .all)
        #expect(app.arrangement.shelf == .toRead)

        // Left on a grid, Go to Library is still the landing's rails.
        app.libraryMode = .all
        app.arrangement.shelf = .finished
        app.showLibrary(fromReading: nil)
        #expect(app.libraryMode == .browse)
        #expect(app.arrangement.shelf == .all)
    }

    // MARK: - R-58

    /// A bare year is stored as its first midnight in UTC.
    @Test("the book page's year is the year the server meant, west of Greenwich too")
    func publishedYearReadsUTC() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "1994-01-01T00:00:00Z"))
        #expect(BookDetailView.publishedYear(date) == "1994")
        // The same as the More by page's caption for a book with no series.
        let book = SharedFixtures.book("Emma")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any] ?? [:]
        json["publicationDate"] = "1994-01-01T00:00:00.000Z"
        let dated = try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: json))
        let published = try #require(dated.publicationDate?.value)
        #expect(BookDetailView.publishedYear(published) == StagedBooks.authorCaption(for: dated))
    }

    // MARK: - R-61

    @Test("a tag page stages its books once, not on every body")
    func stagingIsKept() {
        let cache = StagingCache()
        let books = (0 ..< 50).map { SharedFixtures.book("Book \($0)", uuid: "b\($0)") }
        let first = cache.staged(books: books, statuses: [])
        let again = cache.staged(books: books, statuses: [])
        #expect(first == again)
        #expect(cache.builds == 1, "the page staged its books again for a body that changed nothing")
        _ = cache.staged(books: Array(books.dropLast()), statuses: [])
        #expect(cache.builds == 2, "a changed list must be staged again")
    }

    @Test("the bar's title follows a crossing, not every scrolled point")
    func titleCrossing() {
        #expect(!BookListPage.hasScrolledPast(120, offset: 0))
        #expect(!BookListPage.hasScrolledPast(120, offset: 119))
        #expect(BookListPage.hasScrolledPast(120, offset: 120))
        #expect(!BookListPage.hasScrolledPast(.greatestFiniteMagnitude, offset: 10_000))
    }

    // MARK: - R-47

    /// "Resume download" threw away the Wi-Fi rule's refusal that Save and
    /// Try again, refused for the same reason, put in an alert.
    @Test("a resumed download the Wi-Fi rule refuses is said, as a save is")
    func resumeRefusalIsSaid() async throws {
        let fixture = DownloadRefusalTests.fixture()
        defer { fixture.tearDown() }
        let book = try #require(fixture.app.books.first)

        let resumed = await BookActions.startDownload(.resume, of: book, format: .readaloud, in: fixture.app)
        #expect(resumed?.message == DownloadRefusalTests.expectedReason, "the refusal went unsaid")

        let saved = await BookActions.startDownload(.save, of: book, format: .readaloud, in: fixture.app)
        #expect(saved?.message == DownloadRefusalTests.expectedReason)
    }
}
