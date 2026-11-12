import IssaCore

/// Which screen a book opens on a television.
///
/// Here rather than beside the screens for the reason `TVFocusMoves` is: the
/// tvOS target has no test bundle, and a rule declared there is unreachable
/// from any test.
enum TVBookScreen: Equatable {
    /// The read-along screen: the page, the narration if there is one, and the
    /// message that says so when a book has nothing to open.
    case readalong
    /// The audiobook player.
    case audiobook

    /// A book with a read-along opens it, narration and text together. One
    /// with an audiobook and no read-along opens the player, whether or not it
    /// also has an ebook, since a page with no narration beside it leaves the
    /// audio out of reach. An ebook alone opens the page. One with nothing the
    /// server can serve stays on the read-along screen, which says so.
    static func screen(for book: Book) -> TVBookScreen {
        let formats = book.servableFormats
        if formats.contains(.readaloud) { return .readalong }
        if formats.contains(.audiobook) { return .audiobook }
        return .readalong
    }
}
