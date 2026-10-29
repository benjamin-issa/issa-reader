import Testing

@testable import IssaReader_iOS

/// The reader's top bar never opens a menu of one row.
///
/// iOS opens a menu out of its button, so one row sits on the bar, over the
/// tools beside the button, in a glass they show through. 1.5.2's first build
/// did that whenever no sentence was lit: Find and Marks had moved into the
/// bar, Stop Narration hid itself, and Contents was left alone in the menu.
/// That the open menu reaches below the bar is
/// `LayoutSweepTests.assertEllipsisMenuHoldsContents`, which measures it.
@Suite("Reader top-bar overflow")
struct ReaderOverflowTests {
    private static let combinations: [(foldsFind: Bool, foldsMarks: Bool, hasNarration: Bool)] =
        [false, true].flatMap { find in
            [false, true].flatMap { marks in
                [false, true].map { (find, marks, $0) }
            }
        }

    @Test("No combination makes a menu of one row")
    func neverOneRow() {
        for c in Self.combinations {
            let overflow = ReaderOverflow(
                foldsFind: c.foldsFind, foldsMarks: c.foldsMarks, hasNarration: c.hasNarration)
            if case .menu(let rows) = overflow {
                #expect(rows.count >= 2, "a one-row menu for \(c)")
            }
        }
    }

    @Test("A narrated book's menu always lists Contents, then Stop Narration")
    func narratedBookKeepsTheMenu() {
        for c in Self.combinations where c.hasNarration {
            let overflow = ReaderOverflow(
                foldsFind: c.foldsFind, foldsMarks: c.foldsMarks, hasNarration: true)
            guard case .menu(let rows) = overflow else {
                Issue.record("no menu for \(c)")
                continue
            }
            #expect(Array(rows.suffix(2)) == [.contents, .stopNarration])
        }
        // On a phone nothing is folded, and that menu is exactly the two.
        #expect(ReaderOverflow(foldsFind: false, foldsMarks: false, hasNarration: true)
            == .menu([.contents, .stopNarration]))
    }

    @Test("A book with nothing to narrate and nothing folded has a Contents button")
    func plainBookHasContentsButton() {
        #expect(ReaderOverflow(foldsFind: false, foldsMarks: false, hasNarration: false)
            == .contentsButton)
    }

    @Test("Folded tools come first, in the bar's order")
    func foldedToolsComeFirst() {
        #expect(ReaderOverflow(foldsFind: true, foldsMarks: false, hasNarration: false)
            == .menu([.find, .contents]))
        #expect(ReaderOverflow(foldsFind: true, foldsMarks: true, hasNarration: true)
            == .menu([.find, .marks, .contents, .stopNarration]))
    }
}
