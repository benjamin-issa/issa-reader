package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.TestEpub
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.testServices
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.render.LocatorAnchoring
import com.benjaminissa.issareader.render.TextRange
import com.benjaminissa.issareader.render.android.ChapterLayout
import kotlinx.coroutines.CoroutineScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Where a stored highlight is drawn, when the chapter is no longer exactly
 * the chapter it was marked in. Ported from `HighlightAnchoringTests.swift`.
 *
 * A highlight is saved with the offset of its own first character, which is
 * only as stable as the rendered text: on 2026-09-17 the renderer stopped
 * keeping the space pretty-printed markup leaves between two blocks, which
 * moved every character by one per paragraph above it.
 */
class HighlightAnchoringTest : AppSuite() {
    private fun annotation(excerpt: String, offset: Int?, before: String? = null) = Annotation(
        bookUuid = "b", kind = Annotation.Kind.HIGHLIGHT,
        locator = ReadiumLocator(
            href = "ch01.xhtml", type = "application/xhtml+xml",
            locations = ReadiumLocator.Locations(progression = 0.1, totalProgression = 0.1, charOffset = offset),
            text = before?.let { ReadiumLocator.Text(before = it, highlight = excerpt) },
        ),
        excerpt = excerpt,
    )

    /** Where the mark is found, by the function `anchorAnnotations` calls. */
    private fun anchored(annotation: Annotation, text: String): Int? = ReaderModel.anchoredRange(annotation, text)?.location

    private fun String.substring(range: TextRange) = substring(range.location, range.end)

    /** The ordinary case, and the one that must stay cheap: nothing has moved. */
    @Test
    fun exactHit() {
        val text = "The Wart was the youngest, and the least considered."
        val found = anchored(annotation("youngest", 17), text)
        assertEquals(17, found)
        assertEquals("youngest", text.substring(found!!, found + 8))
    }

    /** An offset the text has moved under finds its words again. */
    @Test
    fun shiftedText() {
        // Two characters inserted ahead of the mark.
        val text = "  The Wart was the youngest, and the least considered."
        val found = checkNotNull(anchored(annotation("youngest", 17), text))
        assertEquals(19, found)
        assertEquals("youngest", text.substring(found, found + 8))
    }

    /** A phrase that occurs twice resolves to the nearer occurrence. */
    @Test
    fun nearestOccurrence() {
        val text = "he said nothing. She waited. he said nothing again."
        assertEquals(29, anchored(annotation("he said nothing", 27), text))
        assertEquals(0, anchored(annotation("he said nothing", 2), text))
    }

    /** Words the chapter no longer holds fall back to the stored offset. */
    @Test
    fun excerptGone() {
        val text = "Nothing here resembles the mark."
        assertEquals(7, anchored(annotation("a phrase from another book", 7), text))
    }

    /** A mark with no offset and no match is nothing to draw. */
    @Test
    fun nothingToGoOn() {
        val text = "Nothing here resembles the mark."
        assertNull(anchored(annotation("absent", null), text))
        assertNull(anchored(annotation("", null), text))
    }

    // Words across a paragraph break, and words too short to trust

    /** C-08: a highlight across a paragraph break is found where it is now. */
    @Test
    fun acrossAParagraphBreak() {
        val text = "The first paragraph ends here.\nThe second one begins now."
        val truth = text.indexOf("ends here")
        // As `annotate` stores it, made three characters further up the page.
        val mark = annotation("ends here. The second", truth + 3)

        val found = checkNotNull(ReaderModel.anchoredRange(mark, text))
        assertEquals(truth, found.location)
        assertEquals("ends here.\nThe second", text.substring(found))
    }

    /** A highlight made under the old renderer is painted over its own words, not past them. */
    @Test
    fun oldDoubleSpace() {
        val text = "The first paragraph ends here.\nThe second one begins now."
        val truth = text.indexOf("ends here")
        val excerpt = "ends here.  The second"
        val mark = annotation(excerpt, truth + 1)

        val found = checkNotNull(ReaderModel.anchoredRange(mark, text))
        assertEquals(truth, found.location)
        assertEquals(excerpt.length - 1, found.length)
    }

    /** A one-word highlight lands on the word that was marked, not the nearest copy. */
    @Test
    fun oneWordMark() {
        val paragraphs = (1..12).map { "Line $it." } + listOf("In the hall the dog slept, then woke.")
        val text = paragraphs.joinToString("\n")
        val old = paragraphs.joinToString("\n ")
        val marked = old.indexOf("the hall")
        val before = old.substring(marked - 32, marked).replace("\n", " ")

        val found = checkNotNull(ReaderModel.anchoredRange(annotation("the", marked, before), text))
        assertEquals(TextRange(text.indexOf("the hall"), 3), found)
    }

    // Opening a mark, and finding a bookmark, on the page it is on

    /** A word whose old offset — one late for every paragraph break above it — is on the page after its own. */
    private class Place(val truth: Int, val old: Int, val page: Int)

    private fun placeWhoseOldOffsetIsOnTheNextPage(layout: ChapterLayout): Place? {
        val text = layout.text
        var breaks = 0
        for (index in text.indices) {
            val unit = text[index]
            if (unit == '\n') {
                breaks += 1
                continue
            }
            if (index == 0 || text[index - 1] != ' ' || !unit.isLetter()) continue
            val old = index + breaks
            if (old >= text.length) continue
            val here = layout.pages.firstOrNull { index in it.characterRange } ?: continue
            val there = layout.pages.firstOrNull { old in it.characterRange } ?: continue
            if (there.index != here.index + 1) continue
            return Place(index, old, here.index)
        }
        return null
    }

    private class Opened(val model: ReaderModel, val server: StubServer, val scope: CoroutineScope) {
        fun tearDown() {
            server.close()
            scope.close()
        }
    }

    private suspend fun model(): Opened {
        val scope = testScope()
        val server = StubServer { Answer(404) }
        val model = ReaderModel(SharedFixtures.book("Marks", uuid = "highlight-anchoring-uuid"), server.session(), testServices(scope))
        // A jump saves, and a save with nowhere to go would go to the network.
        model.enqueuePosition = { _, _, _ -> true }
        model.epubPackage = TestEpub.epubPackage(chapters = listOf(longChapter))
        // `resize` before `go`: it records the page size.
        model.resize(pageSize)
        model.go(toChapter = 0)
        return Opened(model, server, scope)
    }

    /**
     * C-07. The mark is painted on its own page, but the marks list opened
     * the page its stale offset named — the one after, with nothing marked
     * on it — and saved that as the reader's own choice.
     */
    @Test
    fun aStaleMarkOpensOnItsOwnPage() = mainTest {
        val opened = model()
        try {
            val model = opened.model
            val layout = checkNotNull(model.layout)
            val place = checkNotNull(placeWhoseOldOffsetIsOnTheNextPage(layout))
            val text = layout.text
            val excerpt = text.substring(place.truth, place.truth + 24).replace("\n", " ").trim()
            val mark = Annotation(
                bookUuid = "highlight-anchoring-uuid", kind = Annotation.Kind.HIGHLIGHT,
                locator = ReadiumLocator(
                    href = TestEpub.href(longChapter), type = "application/xhtml+xml",
                    locations = ReadiumLocator.Locations(charOffset = place.old),
                    text = LocatorAnchoring.quote(oldRendering(text), place.old, 24),
                ),
                excerpt = excerpt,
            )
            model.loadAnnotations(listOf(mark))
            assertTrue("the mark is drawn on the page its words are on", model.highlightBlocks(layout.pages[place.page]).isNotEmpty())
            model.pageIndex = layout.pages.size - 1

            model.go(mark)

            assertEquals("and the marks list opens that page, not the one after", place.page, model.pageIndex)
        } finally {
            opened.tearDown()
        }
    }

    /**
     * C-07's other half. A bookmark was matched to a page by its stored
     * offset alone, so one made under the old renderer showed on the page
     * after its own — and tapping the button on its own page added a second.
     */
    @Test
    fun aStaleBookmarkIsOnItsOwnPage() = mainTest {
        val opened = model()
        try {
            val model = opened.model
            val layout = checkNotNull(model.layout)
            val place = checkNotNull(placeWhoseOldOffsetIsOnTheNextPage(layout))
            val oldText = oldRendering(layout.text)
            // What `locator(range)` wrote for it: the sentence under its first
            // character, its offset, and the first eighty characters from there.
            val sentence = layout.fragmentRanges.entries.firstOrNull { place.truth in it.value }?.key
            val quote = checkNotNull(LocatorAnchoring.quote(oldText, place.old, 80))
            val bookmark = Annotation(
                bookUuid = "highlight-anchoring-uuid", kind = Annotation.Kind.BOOKMARK,
                locator = ReadiumLocator(
                    href = TestEpub.href(longChapter), type = "application/xhtml+xml",
                    locations = ReadiumLocator.Locations(
                        fragments = sentence?.let { listOf(it) },
                        progression = place.old.toDouble() / oldText.length.toDouble(),
                        charOffset = place.old,
                    ),
                    text = quote,
                ),
                excerpt = quote.highlight ?: "",
            )
            model.loadAnnotations(listOf(bookmark))

            model.pageIndex = place.page
            assertTrue("the page the bookmark's words are on carries it", model.isPageBookmarked)
            model.pageIndex = place.page + 1
            assertFalse("and the page after does not", model.isPageBookmarked)

            model.pageIndex = place.page
            model.toggleBookmark()
            assertTrue("the toggle on its own page removes it, not adds a second", model.annotations.isEmpty())
        } finally {
            opened.tearDown()
        }
    }

    /** A bookmark made now is on the page it was made on. */
    @Test
    fun aFreshBookmarkIsOnItsPage() = mainTest {
        val opened = model()
        try {
            val model = opened.model
            val layout = checkNotNull(model.layout)
            assertTrue("the chapter has to run to several pages", layout.pages.size > 3)
            for (page in listOf(1, 2, layout.pages.size - 1)) {
                model.pageIndex = page
                assertFalse(model.isPageBookmarked)
                model.toggleBookmark()
                assertTrue("page $page carries the bookmark just made", model.isPageBookmarked)
                model.pageIndex = page - 1
                assertFalse("and page ${page - 1} does not", model.isPageBookmarked)
                model.pageIndex = page
                model.toggleBookmark()
                assertTrue(model.annotations.isEmpty())
            }
        } finally {
            opened.tearDown()
        }
    }

    private companion object {
        /**
         * Sixty short paragraphs, each a sentence with an id of its own as a
         * read-along has them: enough paragraph breaks that the old
         * renderer's offset for a place near the foot of a page is on the next one.
         */
        val longChapter = TestEpub.Chapter(
            id = "long", title = "A Long Chapter",
            body = (0 until 60).joinToString("") { n ->
                "<p><span id=\"s$n\">Paragraph $n holds mark $n, word $n, line $n and end $n.</span></p>"
            },
        )
        val pageSize = PageSize(300.0, 400.0)

        /** The chapter as the old renderer laid it out: a space after every newline. */
        fun oldRendering(text: String): String = text.replace("\n", "\n ")
    }
}
