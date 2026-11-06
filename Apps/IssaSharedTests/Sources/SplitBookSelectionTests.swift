import IssaCore
import SwiftUI
import Testing

@testable import IssaReader_iOS

/// iPhone Duo's book page, moving between the pane on the inner display and
/// the stack on the outer one.
///
/// Most screens are pushed by `NavigationLink(destination:)`, and the reader is
/// a cover on the book's page, so neither shows in a `NavigationPath`. These
/// model a page opened from the collapsed one the way the app sees it: the path
/// unchanged, and the page reporting that it left view.
@Suite("Opening the Duo puts back only the page closing pushed")
@MainActor
struct SplitBookSelectionTests {
    static let dracula = SharedFixtures.book("Dracula", uuid: "dracula")
    static let emma = SharedFixtures.book("Emma", uuid: "emma")

    static func closed() -> (selection: SplitBookSelection, path: NavigationPath) {
        let selection = SplitBookSelection()
        selection.book = dracula
        var path = NavigationPath()
        selection.close(&path)
        return (selection, path)
    }

    @Test("closing moves the page to the stack, and opening moves it back")
    func closingAndOpening() {
        var (selection, path) = Self.closed()
        #expect(selection.book == nil)
        #expect(path.count == 1)

        selection.open(&path)

        #expect(selection.book?.uuid == Self.dracula.uuid)
        #expect(path.isEmpty)
    }

    @Test("closing with no book chosen pushes nothing, and opening restores nothing")
    func nothingChosen() {
        let selection = SplitBookSelection()
        var path = NavigationPath()
        selection.close(&path)
        #expect(path.isEmpty)
        selection.open(&path)
        #expect(selection.book == nil)
    }

    /// The reported bug. Read, or a link, on the outer display leaves the path
    /// exactly as close left it, so the path alone said the page was free, and
    /// opening took it out from under whatever had been opened from it.
    @Test("a page opened over the collapsed one holds the split")
    func aCoveredPageHolds() {
        let (selection, path) = Self.closed()
        #expect(!selection.holdsSplit(given: path))

        selection.pageDisappeared(Self.dracula)

        #expect(selection.holdsSplit(given: path))
    }

    @Test("coming back to the collapsed page lets the split go on")
    func uncoveredReleases() {
        var (selection, path) = Self.closed()
        selection.pageDisappeared(Self.dracula)

        selection.pageAppeared(Self.dracula)

        #expect(!selection.holdsSplit(given: path))
        selection.open(&path)
        #expect(selection.book?.uuid == Self.dracula.uuid)
        #expect(path.isEmpty)
    }

    @Test("another book's page coming and going says nothing about the collapsed one")
    func anotherBooksPage() {
        let (selection, path) = Self.closed()

        selection.pageDisappeared(Self.emma)
        #expect(!selection.holdsSplit(given: path))

        selection.pageDisappeared(Self.dracula)
        selection.pageAppeared(Self.emma)
        #expect(selection.holdsSplit(given: path))
    }

    /// Going Back makes the page disappear too, and nothing is over it then.
    /// Held on that, the phone would never divide again.
    @Test("Back from the collapsed page holds nothing, and leaves it gone")
    func wentBack() {
        var (selection, path) = Self.closed()
        path.removeLast()
        selection.pageDisappeared(Self.dracula)

        #expect(!selection.holdsSplit(given: path))
        selection.open(&path)

        #expect(selection.book == nil, "the reader left this page")
        #expect(path.isEmpty)
    }

    @Test("a stack replaced at the same depth holds nothing, and stays")
    func replacedAtTheSameDepth() {
        var (selection, path) = Self.closed()
        selection.pageDisappeared(Self.dracula)
        path = NavigationPath()
        path.append(Self.emma)
        let linked = path

        #expect(!selection.holdsSplit(given: path))
        selection.open(&path)

        #expect(path == linked, "the page the reader is on stays where it is")
        #expect(selection.book == nil, "and the one they left does not come back")
    }

    @Test("a later open has nothing left to restore")
    func onlyOnce() {
        var (selection, path) = Self.closed()
        path.removeLast()
        selection.open(&path)

        selection.open(&path)

        #expect(selection.book == nil)
    }

    // MARK: - A book asked for from outside

    @Test("a link goes in the pane where there is one, and clears the stack")
    func aLinkWithThePaneOpen() {
        let selection = SplitBookSelection()
        selection.isSplit = true
        var path = NavigationPath()
        path.append(Self.dracula)

        selection.show(Self.emma, in: &path)

        #expect(selection.book?.uuid == Self.emma.uuid)
        #expect(path.isEmpty, "not in the shelf's half of the display")
    }

    /// Left on the stack, it sat in the shelf's half of the display when the
    /// phone opened, beside an empty pane.
    @Test("a link on the outer display goes in the pane when the phone opens")
    func aLinkWithThePhoneClosed() {
        var (selection, path) = Self.closed()

        selection.show(Self.emma, in: &path)
        #expect(path.count == 1)
        #expect(selection.book == nil)

        selection.open(&path)

        #expect(selection.book?.uuid == Self.emma.uuid)
        #expect(path.isEmpty)
    }

    @Test("a link to the book already in the pane builds its page again")
    func aLinkToThePaneBook() {
        let selection = SplitBookSelection()
        selection.isSplit = true
        selection.book = Self.dracula
        var path = NavigationPath()
        let before = selection.requests

        selection.show(Self.dracula, in: &path)

        #expect(selection.requests != before, "or a request to read it is never taken up")
    }
}
