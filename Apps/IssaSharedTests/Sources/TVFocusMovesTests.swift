import Testing

@testable import IssaReader_iOS

/// Down on the remote, on a book with no narration.
///
/// `TVPageView` sent focus to `.transport` on every Down, and on a plain ebook
/// no view claimed that value — so focus left the page, `onMoveCommand` (which
/// is attached to the page) stopped receiving anything, Left and Right stopped
/// turning pages, and the reader's only way out was Menu, which leaves the book
/// altogether. The suite exists because the tvOS target has no test bundle:
/// this is the only place the rule can be asserted at all.
@Suite("Where the remote's ring leaves focus")
struct TVFocusMovesTests {
    @Test("down from the page reaches the transport on a narrated book")
    func downReachesTheTransport() {
        #expect(TVFocusMoves.destination(
            for: .down, from: .page, hasNarration: true,
        ) == .transport)
    }

    /// The finding itself. Nothing below the page is worth sending a reader to
    /// on a book with no narration, and sending them there anyway cost them
    /// every page turn.
    @Test("down from the page stays on the page when the book has no narration")
    func downStaysPutWithoutNarration() {
        #expect(TVFocusMoves.destination(
            for: .down, from: .page, hasNarration: false,
        ) == nil)
    }

    @Test("up from the transport returns to the page")
    func upReturnsToThePage() {
        #expect(TVFocusMoves.destination(
            for: .up, from: .transport, hasNarration: true,
        ) == .page)
        // The row exists on a plain ebook too, saying so, and Up has to bring
        // the reader back from it whatever put them there.
        #expect(TVFocusMoves.destination(
            for: .up, from: .transport, hasNarration: false,
        ) == .page)
    }

    /// Left and Right turn the page. A move that also moved focus would take
    /// the page turner away from the page on the first press.
    @Test("left and right move no focus at all")
    func sidewaysMovesNothing() {
        for narrated in [true, false] {
            #expect(TVFocusMoves.destination(
                for: .left, from: .page, hasNarration: narrated,
            ) == nil)
            #expect(TVFocusMoves.destination(
                for: .right, from: .page, hasNarration: narrated,
            ) == nil)
            #expect(TVFocusMoves.destination(
                for: .left, from: .transport, hasNarration: narrated,
            ) == nil)
            #expect(TVFocusMoves.destination(
                for: .right, from: .transport, hasNarration: narrated,
            ) == nil)
        }
    }

    /// There is nothing above the page and nothing below the transport, and a
    /// move that answers with the row it started on would re-assign focus for
    /// no reason on every press.
    @Test("a move with nowhere to go answers with nowhere")
    func movesOffTheEndsAnswerNil() {
        #expect(TVFocusMoves.destination(for: .up, from: .page, hasNarration: true) == nil)
        #expect(TVFocusMoves.destination(for: .up, from: .page, hasNarration: false) == nil)
        #expect(TVFocusMoves.destination(for: .down, from: .transport, hasNarration: true) == nil)
        #expect(TVFocusMoves.destination(for: .down, from: .transport, hasNarration: false) == nil)
    }
}
