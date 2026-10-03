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

    /// Whether the switch takes a click: not on a named shelf, and not while a
    /// search is showing results.
    static func isEnabled(_ state: State) -> Bool {
        state.shelf == .all && !state.isSearching
    }

    /// What picking a segment leaves the library as.
    static func picking(_ mode: AppModel.LibraryMode, in state: State) -> State {
        guard isEnabled(state) else { return state }
        var next = state
        next.mode = mode
        return next
    }
}
