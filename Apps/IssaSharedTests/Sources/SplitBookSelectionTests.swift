import IssaCore
import SwiftUI
import Testing

@testable import IssaReader_iOS

/// iPhone Duo's book page, moving between the pane on the inner display and
/// the stack on the outer one.
///
/// Opening took the stack's last page on trust, whatever it had become since
/// the close: after a link to another book it removed that book and brought
/// back the one the reader had left.
@Suite("Opening the Duo puts back only the page closing pushed")
@MainActor
struct SplitBookSelectionTests {
    static let dracula = SharedFixtures.book("Dracula", uuid: "dracula")
    static let emma = SharedFixtures.book("Emma", uuid: "emma")

    static func closed() -> (SplitBookSelection, NavigationPath) {
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

    @Test("Back from the page on the outer display leaves it gone")
    func wentBack() {
        var (selection, path) = Self.closed()
        path.removeLast()

        selection.open(&path)

        #expect(selection.book == nil, "the reader left this page")
        #expect(path.isEmpty)
    }

    /// The same depth, so only comparing the stack itself can tell.
    @Test("a link to another book at the same depth stays on the stack")
    func replacedAtTheSameDepth() {
        var (selection, path) = Self.closed()
        path = NavigationPath()
        path.append(Self.emma)
        let linked = path

        selection.open(&path)

        #expect(path == linked, "the page the reader is on stays where it is")
        #expect(selection.book == nil, "and the one they left does not come back")
    }

    @Test("a page pushed on top of it stays")
    func pushedDeeper() {
        var (selection, path) = Self.closed()
        path.append(Self.emma)

        selection.open(&path)

        #expect(path.count == 2)
        #expect(selection.book == nil)
    }

    /// Once only: it does not linger to act on a later open.
    @Test("a later open has nothing left to restore")
    func onlyOnce() {
        var (selection, path) = Self.closed()
        path.removeLast()
        selection.open(&path)

        selection.open(&path)

        #expect(selection.book == nil)
    }
}
