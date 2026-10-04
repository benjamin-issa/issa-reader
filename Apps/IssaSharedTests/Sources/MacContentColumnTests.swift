import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// The Mac library window's content column: which sidebar row, and which
/// pages over it. Asked from the phone's test bundle, as `MacDecisionsTests`
/// asks the menu bar's decisions: no test can drive the Mac's window.
@Suite("The Mac's content column")
@MainActor
struct MacContentColumnTests {
    @Test("a sidebar row takes down the pages pushed over the last one")
    func sidebarChangeEmptiesThePath() {
        var column = MacContentColumn()
        column.select(.reading)
        column.push(.tag("Gothic"))
        #expect(column.path == [.tag("Gothic")])

        column.select(.shelf(.all))
        #expect(column.selection == .shelf(.all))
        #expect(column.path.isEmpty, "a tag page opened from Reading survived the move to All books")
    }

    @Test("picking the row already shown leaves its pages alone")
    func sameRowKeepsThePath() {
        var column = MacContentColumn()
        column.push(.author("Jane Austen"))
        column.select(.shelf(.all))
        #expect(column.path == [.author("Jane Austen")])
    }

    @Test("Show in Library leaves the page for All books, from any row")
    func showLibraryPops() {
        var column = MacContentColumn()
        column.select(.shelf(.toRead))
        column.push(.tag("Gothic"))
        column.push(.series("Dracula's Guest"))
        column.showLibrary()
        #expect(column.selection == .shelf(.all))
        #expect(column.path.isEmpty)

        // And when All books is already the row: the page still goes.
        column.push(.tag("Gothic"))
        column.showLibrary()
        #expect(column.path.isEmpty)
    }

    @Test("a push is a page: never a book's details, never the same page twice")
    func pushes() {
        var column = MacContentColumn()
        column.push(.details(SharedFixtures.book("Dracula", uuid: "dracula")))
        #expect(column.path.isEmpty)
        column.push(.tag("Gothic"))
        column.push(.tag("Gothic"))
        #expect(column.path == [.tag("Gothic")])
        column.push(.author("Bram Stoker"))
        #expect(column.path == [.tag("Gothic"), .author("Bram Stoker")])
    }

    /// Settings' "Show in Library" selected the book and left whatever page
    /// was up, and a shelf without the book, in the way (F10).
    @Test("a book revealed from outside is shown on the library, page taken down")
    func revealBook() {
        var column = MacContentColumn()
        column.select(.shelf(.toRead))
        column.push(.author("Jane Austen"))
        column.revealBook(isOnCurrentShelf: true)
        #expect(column.selection == .shelf(.toRead))
        #expect(column.path.isEmpty)

        column.revealBook(isOnCurrentShelf: false)
        #expect(column.selection == .shelf(.all))

        column.select(.downloads)
        column.revealBook(isOnCurrentShelf: true)
        #expect(column.selection == .shelf(.all), "Downloads is not a shelf the book can be shown on")
    }

    @Test("a page's switch lands on the library's All books")
    func switchFromAPage() {
        #expect(LibraryModeSwitch.showsRails(LibraryModeSwitch.fromPage(.browse)))
        let grid = LibraryModeSwitch.fromPage(.all)
        #expect(!LibraryModeSwitch.showsRails(grid))
        #expect(grid.shelf == .all && !grid.isSearching)
    }
}
