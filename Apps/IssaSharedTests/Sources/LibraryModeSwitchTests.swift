import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// The Mac library toolbar's Browse / All Books switch.
///
/// Reported against 1.3.0 as "the Browse button isn't working". The switch was
/// disabled on every shelf but All books and whenever the search field held
/// anything, and the Mac reaches those states without being asked to: the
/// Reading screen's "See all" lands on To read or Downloaded, a "With audio"
/// rail's "See all" on With narration, an author page's "Show in Library" on a
/// search, and the shelf is restored at launch. A disabled segment on the
/// toolbar's glass reads as a live one, so Browse looked clickable and did
/// nothing. These pin what a click on each segment has to leave on screen.
@Suite("Mac library mode switch")
struct LibraryModeSwitchTests {
    typealias State = LibraryModeSwitch.State

    static let namedShelves = LibraryArrangement.Shelf.allCases.filter { $0 != .all }

    @Test("Browse from a named shelf shows the rails, on All books")
    func browseFromANamedShelf() {
        for shelf in Self.namedShelves {
            for mode in [AppModel.LibraryMode.all, .browse] {
                let before = State(mode: mode, shelf: shelf, isSearching: false)
                let after = LibraryModeSwitch.picking(.browse, in: before)
                #expect(LibraryModeSwitch.showsRails(after),
                        "Browse on \(shelf.title) left the grid on screen: \(after)")
                #expect(after.shelf == .all, "the sidebar would still claim \(after.shelf.title)")
                #expect(LibraryModeSwitch.shown(after) == .browse)
            }
        }
    }

    @Test("Browse over search results clears the search and shows the rails")
    func browseOverASearch() {
        for shelf in LibraryArrangement.Shelf.allCases {
            let before = State(mode: .all, shelf: shelf, isSearching: true)
            let after = LibraryModeSwitch.picking(.browse, in: before)
            #expect(!after.isSearching, "the results would still cover the rails")
            #expect(LibraryModeSwitch.showsRails(after), "Browse over a search on \(shelf.title) did nothing")
        }
    }

    @Test("Browse from the All books grid shows the rails")
    func browseFromTheGrid() {
        let after = LibraryModeSwitch.picking(.browse, in: State(mode: .all, shelf: .all, isSearching: false))
        #expect(after == State(mode: .browse, shelf: .all, isSearching: false))
        #expect(LibraryModeSwitch.showsRails(after))
    }

    /// The other segment changes the mode and nothing else: the grid keeps its
    /// shelf, and a search keeps its results.
    @Test("All Books keeps the shelf and the search")
    func allBooksKeepsTheCut() {
        for shelf in LibraryArrangement.Shelf.allCases {
            for isSearching in [false, true] {
                let after = LibraryModeSwitch.picking(
                    .all, in: State(mode: .browse, shelf: shelf, isSearching: isSearching))
                #expect(after == State(mode: .all, shelf: shelf, isSearching: isSearching))
                #expect(!LibraryModeSwitch.showsRails(after))
            }
        }
    }

    /// The segment never claims Browse over a grid.
    @Test("the segment reads Browse only over the rails")
    func segmentReadsWhatIsOnScreen() {
        for shelf in LibraryArrangement.Shelf.allCases {
            for mode in [AppModel.LibraryMode.all, .browse] {
                for isSearching in [false, true] {
                    let state = State(mode: mode, shelf: shelf, isSearching: isSearching)
                    let rails = mode == .browse && shelf == .all && !isSearching
                    #expect(LibraryModeSwitch.showsRails(state) == rails)
                    #expect(LibraryModeSwitch.shown(state) == (rails ? .browse : .all))
                }
            }
        }
    }
}
