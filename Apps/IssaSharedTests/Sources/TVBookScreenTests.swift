import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// What a title opens on the television: the read-along screen has no way to
/// play an audiobook, so a title with audio and no read-along ended on "no
/// readable edition", or on text with "No narration for this book".
@Suite("Which screen a book opens on the television")
struct TVBookScreenTests {
    @Test("a read-along opens the read-along screen")
    func readalong() {
        let book = SharedFixtures.book("Peter and Wendy", readaloud: true)
        #expect(TVBookScreen.screen(for: book) == .readalong)
        // Even with an audiobook beside it.
        let both = SharedFixtures.book("Peter and Wendy", readaloud: true, audiobook: true)
        #expect(TVBookScreen.screen(for: both) == .readalong)
    }

    @Test("an audiobook with no read-along opens the player, with or without an ebook")
    func audiobook() {
        let only = SharedFixtures.book("Dracula", audiobook: true, ebook: false)
        #expect(TVBookScreen.screen(for: only) == .audiobook)
        let withEbook = SharedFixtures.book("Dracula", audiobook: true, ebook: true)
        #expect(TVBookScreen.screen(for: withEbook) == .audiobook)
    }

    @Test("an ebook alone opens the read-along screen")
    func ebookOnly() {
        #expect(TVBookScreen.screen(for: SharedFixtures.book("Emma")) == .readalong)
    }

    @Test("an audiobook the server has lost, with nothing else, is not the player")
    func missingAudiobook() throws {
        var book = SharedFixtures.book("Dracula", audiobook: true, ebook: false)
        book.audiobook?.missing = true
        #expect(TVBookScreen.screen(for: book) == .readalong)
        #expect(book.servableFormats.isEmpty)
        // And a lost audiobook beside a working ebook is the ebook's.
        var withEbook = SharedFixtures.book("Dracula", audiobook: true, ebook: true)
        withEbook.audiobook?.missing = true
        #expect(TVBookScreen.screen(for: withEbook) == .readalong)
    }
}
