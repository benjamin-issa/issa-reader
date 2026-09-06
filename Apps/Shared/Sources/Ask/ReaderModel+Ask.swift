#if !os(tvOS)
import Foundation
import IssaAsk
import IssaCore
import IssaEPUB

/// Where the reader has got to, and which file to answer from.
///
/// In its own file rather than in `ReaderModel` because the whole feature is
/// fenced off the television, and because these two are the only things the
/// Ask machinery ever asks the reader for — everything else it needs comes out
/// of the index.
extension ReaderModel {
    /// The line past which the model is never shown anything.
    ///
    /// Computed on the main actor at the moment of asking and then carried by
    /// value: an answer that takes twenty seconds must be bounded by where the
    /// reader was when they asked, and the footer under it has to name the same
    /// place the SQL used.
    ///
    /// The narrated sentence's end when the voice is running in the chapter on
    /// screen, because that is what the reader has actually heard; otherwise the
    /// end of what the page *paints*. Painted, not `characterRange`: a paragraph
    /// taller than the page stays whole on the page it begins on and the draw
    /// pass clips the overflow, so `characterRange` runs on past the last word
    /// the reader can see — which on a long paragraph is a page and a half of
    /// story they have not read.
    func readingBoundary() -> ReadingBoundary? {
        guard let layout, let page = currentPage else { return nil }

        // The voice, when it is in this chapter. A narrated entry from another
        // spine document has no range in this layout, and taking its offset
        // would bound the answer at an arbitrary point in the wrong chapter.
        if isPlaying, let entry = readalong?.activeEntry,
           let href = loadedSpineHref,
           ReadiumLocator(href: entry.textHref, type: "application/xhtml+xml").matchesHref(href),
           let range = layout.fragmentRange(for: entry.fragmentID) {
            return ReadingBoundary(
                spineIndex: chapterIndex,
                charOffset: NSMaxRange(range),
                chapterTitle: chapterTitle,
                pageNumber: pageIndex + 1,
                kind: .narratedSentence,
            )
        }

        // An empty painted range means nothing laid out on this page — a page
        // of a single image, or a layout pass that has not run. The page's own
        // range is the only answer left, and it is the conservative one only in
        // the sense that it is never *shorter*; there is nothing else to use.
        let painted = layout.paintedCharacterRange(for: page)
        let bounded = painted.length > 0 ? painted : page.characterRange
        return ReadingBoundary(
            spineIndex: chapterIndex,
            charOffset: NSMaxRange(bounded),
            chapterTitle: chapterTitle,
            pageNumber: pageIndex + 1,
            kind: .pageEnd,
        )
    }

    /// The file the index is built from: the very edition the reader opened.
    ///
    /// Not "whichever edition the server prefers" — a reader who opened the
    /// plain ebook and an index built from the aligned one would have offsets
    /// that agree by luck rather than by construction, and the boundary above
    /// is a character offset into a *rendered* chapter.
    ///
    /// The package is handed over rather than re-opened: it is a value over an
    /// archive that is nothing but a central directory in memory, and re-opening
    /// costs a second read of the whole EPUB's directory for no gain.
    func askSource() -> BookSource? {
        guard let package,
              let format = BookContentService.preferredReadingFormat(for: book)
        else { return nil }
        let url = BookContentService(client: readerSession.client)
            .localURL(for: book, format: format)
        return BookSource(bookUUID: book.uuid, fileURL: url, package: package)
    }

    /// The href of the spine document currently laid out.
    ///
    /// Spelled here rather than reached for on the model: `ReaderModel` has its
    /// own private accessor for exactly this, and a `private` member is not
    /// visible from another file. The guard is the same one it states — the
    /// index and the package are set independently, so `spine[chapterIndex]` is
    /// not safe to write bare.
    private var loadedSpineHref: String? {
        guard let package, package.spine.indices.contains(chapterIndex) else { return nil }
        return package.spine[chapterIndex].href
    }
}
#endif
