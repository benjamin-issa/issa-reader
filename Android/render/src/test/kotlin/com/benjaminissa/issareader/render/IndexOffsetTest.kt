package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.testing.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The parser half of IssaAsk's `IndexOffsetTests` and
 * `WhitespaceStabilityTests`: what the Ask index's offsets rest on, as far as
 * the string goes. The halves about the store, the chunker and the ranker
 * belong to the Ask port.
 *
 * The spoiler boundary is a comparison of two integers: the reader's position,
 * measured against a chapter laid out by the reader, and a passage's offsets,
 * measured against a chapter parsed by the index. If those two strings differ
 * by so much as one character, every comparison downstream is off by that much
 * — and off in the direction that shows the reader text they have not read.
 */
class IndexOffsetTest {
    /** IssaAsk's copy of *Alice*, and its spine indices: the two wrappers in front are why Chapter I is 2. */
    private val book: EpubPackage by lazy { EpubPackage.open(Fixtures.ask("alice.epub")) }
    private val chapterI = 2
    private val chapterVI = 7

    /** One chapter's rendered string, parsed exactly as the reader and the index parse it. */
    private fun text(spine: Int, style: ReaderStyle = ReaderStyle()): String {
        val href = book.spine[spine].href
        val images = ArchiveImageSource(book.archive)
        return ChapterParser(style, loadImage = { images.image(it) }).parse(book.archive.read(href), href).text
    }

    @Test
    fun `the rendered string is identical under two very different styles`() {
        // The index is built once, with a plain `ReaderStyle()`, and then
        // compared against a reader who may be at 40 pt in the publisher's
        // face, justified, with roomy spacing. Typeface, size and spacing are
        // attributes; if any of them ever changed a character, the index would
        // have to be rebuilt on every font change — and until someone noticed,
        // it would silently point at the wrong place.
        val plain = ReaderStyle()
        val extreme = ReaderStyle(
            typeface = ReaderStyle.Typeface.Publisher,
            fontSize = 40.0,
            lineSpacing = ReaderStyle.LineSpacing.ROOMY,
            justification = ReaderStyle.Justification.ALWAYS,
            pageMargin = 4.0,
        )
        for (spine in listOf(chapterI, chapterVI)) {
            assertEquals("spine $spine", text(spine, plain), text(spine, extreme))
        }
    }

    /** And the reader's layout-time column and page sizes, which scale plates but never add or remove one. */
    @Test
    fun `the column and page sizes never change the string`() {
        for (spine in book.spine.indices) {
            val href = book.spine[spine].href
            val images = ArchiveImageSource(book.archive)
            val reader = ChapterParser(
                ReaderStyle(fontSize = 26.0), maxImageWidth = 200.0, maxImageHeight = 300.0, columnWidth = 200.0,
                loadImage = { images.image(it) },
            ).parse(book.archive.read(href), href)
            assertEquals("spine $spine", text(spine), reader.text)
        }
    }

    /**
     * Chapter I opens with its heading, and the passage the index stores for
     * it begins at offset 0. A stray space or newline left at the front by the
     * trim would move every offset after it by one.
     */
    @Test
    fun `a chapter's string begins at its first word`() {
        val chapter = text(chapterI)
        assertTrue(chapter.isNotEmpty())
        assertTrue(!chapter.first().isWhitespace() && !chapter.last().isWhitespace())
    }
}
