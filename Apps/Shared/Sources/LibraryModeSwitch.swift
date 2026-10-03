import IssaCore

/// The Mac library window's Browse / All Books switch, as decisions.
///
/// The switch lives in the Mac's toolbar and the screen it drives is the Mac
/// branch of `LibraryView`, neither of which a test can reach. What the
/// segment reads, what is on screen and what a click changes are all decided
/// here instead, from plain values, so a hosted test on any platform can ask.
enum LibraryModeSwitch {
    /// What the switch looks at: the library's mode and shelf, and whether a
    /// search is showing results.
    struct State: Equatable {
        var mode: AppModel.LibraryMode
        var shelf: LibraryArrangement.Shelf
        var isSearching: Bool
    }

    /// Whether the content column shows Browse's rails rather than the grid.
    ///
    /// Rails only on All books. The sidebar is the Mac's shelf control, so
    /// picking a shelf there means "show me that cut of the library", which is
    /// the grid; and search results are an answer, shown whichever mode is on.
    static func showsRails(_ state: State) -> Bool {
        state.mode == .browse && state.shelf == .all && !state.isSearching
    }

    /// What the segment reads: "All Books" whenever rails are not what is on
    /// screen, so it never claims Browse over a grid.
    static func shown(_ state: State) -> AppModel.LibraryMode {
        showsRails(state) ? .browse : .all
    }

    /// What picking a segment leaves the library as.
    ///
    /// Browse is the rails, from wherever the library is: it goes to All books
    /// — the sidebar follows the shelf — and leaves the search, because rails
    /// are only ever shown on All books with nothing searched. The switch used
    /// to be disabled everywhere else instead. The Mac lands on a named shelf
    /// without being asked to (the Reading screen's and a "With audio" rail's
    /// "See all", a shelf restored at launch) and on a search (an author's
    /// "Show in Library"), and a disabled segment on the toolbar's glass looks
    /// like a live one, so Browse was a button that did nothing.
    ///
    /// All Books writes the mode and nothing else: the grid keeps the shelf,
    /// sort and tags it already had, and a search keeps its results.
    static func picking(_ mode: AppModel.LibraryMode, in state: State) -> State {
        switch mode {
        case .browse: State(mode: .browse, shelf: .all, isSearching: false)
        case .all: State(mode: .all, shelf: state.shelf, isSearching: state.isSearching)
        }
    }

    /// Where a segment picked on a page pushed over the library lands — a
    /// tag, author or series page, whose toolbar keeps the switch
    /// (`libraryPageToolbar`). The library's All books, as "Show in Library"
    /// goes: Browse is its rails, All Books its grid, and nothing searched.
    static func fromPage(_ picked: AppModel.LibraryMode) -> State {
        State(mode: picked, shelf: .all, isSearching: false)
    }

    /// Where the Reading screen's links into the library land.
    ///
    /// A "See all" names a shelf — Up next's To read, the downloads'
    /// Downloaded — and means that shelf's flat grid, which is what
    /// `AppModel.showAllBooks(shelf:)` does everywhere else. The empty
    /// screen's "Go to Library" names none and means the library's landing:
    /// Browse's rails on All books, with nothing searched. On the Mac the
    /// link used to change only the sidebar and keep the mode, so whichever
    /// the library was last left on decided what "Go to Library" showed.
    static func fromReading(_ shelf: LibraryArrangement.Shelf?) -> State {
        if let shelf {
            State(mode: .all, shelf: shelf, isSearching: false)
        } else {
            State(mode: .browse, shelf: .all, isSearching: false)
        }
    }
}

extension AppModel {
    /// Puts the library where `LibraryModeSwitch.fromReading` says a link
    /// from the Reading screen lands. The caller shows the library, from its
    /// root, so no search or pushed page is left over it.
    func showLibrary(fromReading shelf: LibraryArrangement.Shelf?) {
        let landing = LibraryModeSwitch.fromReading(shelf)
        if landing.mode == .all {
            showAllBooks(shelf: landing.shelf)
        } else {
            arrangement.shelf = landing.shelf
            libraryMode = landing.mode
        }
    }
}
