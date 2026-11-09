package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.render.ReaderStyle
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The assertion the whole spoiler defence rests on.
 *
 * The boundary is a comparison of two integers: the reader's position,
 * measured against a chapter laid out by the reader, and a passage's offsets,
 * measured against a chapter parsed by the index. If those two strings differ
 * by so much as one character, every comparison downstream is off by that much
 * — and off in the direction that shows the reader text they have not read.
 */
class IndexOffsetTest {
    @Test
    fun `stored passages are literal substrings of a fresh parse`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            val indexUrl = store.indexUrl(AskFixture.bookUuid)
            for (spine in listOf(AskFixture.Spine.chapterI, AskFixture.Spine.chapterVI)) {
                val fresh = AskFixture.text(spine)
                val stored = AskFixture.storedPassages(spine, indexUrl)
                assertFalse(stored.isEmpty())
                for (passage in stored) {
                    assertTrue(passage.end <= fresh.length)
                    // Not "contains" — at exactly this offset. A passage that
                    // happens to appear elsewhere in the chapter would pass a
                    // `contains` check while its offsets pointed at the wrong page.
                    assertTrue(fresh.substring(passage.start, passage.end).startsWith(passage.text))
                }
            }
        } finally {
            AskFixture.remove(directory)
        }
    }

    /**
     * The index is built once, with a plain `ReaderStyle()`, and then compared
     * against a reader who may be at 40 pt in the publisher's face, justified,
     * with roomy spacing. `:render` asserts the same of its own parse; this is
     * the copy the Ask suite carries, against the parse the index makes.
     */
    @Test
    fun `the rendered string is identical under two very different styles`() {
        val plain = ReaderStyle()
        val extreme = ReaderStyle(
            typeface = ReaderStyle.Typeface.Publisher,
            fontSize = 40.0,
            lineSpacing = ReaderStyle.LineSpacing.ROOMY,
            justification = ReaderStyle.Justification.ALWAYS,
            pageMargin = 4.0,
        )
        for (spine in listOf(AskFixture.Spine.chapterI, AskFixture.Spine.chapterVI)) {
            assertEquals("spine $spine", AskFixture.text(spine, plain), AskFixture.text(spine, extreme))
        }
    }

    @Test
    fun `chunking a fresh parse reproduces the stored passages exactly`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            val indexUrl = store.indexUrl(AskFixture.bookUuid)
            val titles = AskFixture.epubPackage().navigation.map { it.title }
            // Through `indexable` rather than `chunk`: dropping the contents
            // table is what the store does.
            for (spine in listOf(AskFixture.Spine.chapterI, 1, AskFixture.Spine.chapterVI)) {
                val fresh = PassageChunker.indexable(AskFixture.text(spine), spine, titles)
                val stored = AskFixture.storedPassages(spine, indexUrl)
                // Rebuilding from the same book must give the same offsets.
                assertEquals("spine $spine", fresh, stored)
            }
        } finally {
            AskFixture.remove(directory)
        }
    }

    /** The passage that was cited as evidence for "Who is Alice?", asserted against the rows the store wrote. */
    @Test
    fun `nothing outside the book itself is stored, and the story all is`() = runBlocking {
        val (store, source, directory) = AskFixture.preparedStore()
        try {
            val indexUrl = store.indexUrl(AskFixture.bookUuid)
            // Gutenberg's header page: a legal notice, a credits block and a
            // contents table, and not one sentence of *Alice*.
            assertTrue(AskFixture.storedPassages(1, indexUrl).isEmpty())
            // …and its footer, which is three pages of licence.
            assertTrue(AskFixture.storedPassages(source.epubPackage.spine.size - 1, indexUrl).isEmpty())
            // Every chapter of the story is untouched.
            for (spine in 2..13) {
                assertFalse("spine $spine", AskFixture.storedPassages(spine, indexUrl).isEmpty())
            }
            // And the transcribers are no longer people the reader has met.
            val names = store.topNames(AskFixture.bookUuid, AskFixture.endOf(AskFixture.Spine.chapterVI), limit = 20)
            assertFalse(names.toString(), names.any { it.contains("Widger") || it.contains("Carroll") })
            assertEquals("Alice", names.first())
        } finally {
            AskFixture.remove(directory)
        }
    }
}

/**
 * What must not move when the *rendering* of a chapter changes without its
 * words changing — written after the renderer stopped keeping the space that
 * pretty-printed markup leaves between two blocks, and nothing moved.
 */
class WhitespaceStabilityTest {
    companion object {
        fun spaced(text: String): String = text.replace("\n", "\n ")

        /**
         * A chapter with decisions in it for the chunker to make: short
         * paragraphs that merge until a passage is full, and one paragraph past
         * `maximumWords`, so the sentence splitter runs.
         */
        val decidingChapter: String = run {
            val short = (1..9).map { index ->
                "On the $index day the Wart carried the arrows out to the butts for Kay, and " +
                    "stood at the back of the yard while the elder boy shot, and said nothing " +
                    "about it to anybody at supper."
            }
            val long = (1..8).joinToString(" ") { index ->
                "Sir Ector watched them from the wall on the $index evening and thought about " +
                    "the letter that had come with the second boy."
            }
            (short.take(5) + listOf(long) + short.drop(5)).joinToString("\n")
        }

        /** Text as its words, so a comparison is about what was chosen rather than how it was spaced. */
        fun words(text: String): List<String> = text.splitOnWhitespace()
    }

    /**
     * The same words are cut into the same passages, in the same order,
     * however the blocks were spaced — compared on the words, because
     * `displayText` trims a passage's ends and nothing else.
     */
    @Test
    fun `the same words are chunked the same way, however the blocks are spaced`() {
        val tidy = PassageChunker.indexable(decidingChapter, 3)
        val stray = PassageChunker.indexable(spaced(decidingChapter), 3)

        // The fixture's own shape first, or the comparison below proves nothing.
        assertTrue(tidy.size >= 3)
        val long = decidingChapter.split("\n").first { PassageChunker.wordCount(it) > PassageChunker.Limits.maximumWords }
        val opening = "on the 1 evening"
        val closing = "on the 8 evening"
        assertTrue(long.contains(opening) && long.contains(closing))
        val holdsOpening = tidy.indexOfFirst { it.text.contains(opening) }
        val holdsClosing = tidy.indexOfFirst { it.text.contains(closing) }
        assertTrue(holdsOpening >= 0 && holdsClosing >= 0)
        assertTrue(holdsOpening != holdsClosing)

        assertEquals(tidy.size, stray.size)
        for ((a, b) in tidy.zip(stray)) {
            assertEquals(a.ordinal, b.ordinal)
            assertEquals(a.spineIndex, b.spineIndex)
            assertEquals(words(a.displayText), words(b.displayText))
            // The word count is what the merge and split decisions are made on.
            assertEquals(a.words, b.words)
        }
    }

    @Test
    fun `a passage's score does not depend on the whitespace around it`() {
        val terms = QueryTerms.extract("Who is the Wart's brother?", knownNames = listOf("wart", "kay"))
        fun passage(text: String) = RetrievedPassage(
            Passage(
                spineIndex = 3, ordinal = 7, start = 100, end = 100 + text.length,
                words = PassageChunker.wordCount(text), text = text,
            ),
            bm25 = -4.25,
            isTruncated = false,
        )
        val bare = "Kay was the elder, and the Wart carried his arrows."
        for (spaced in listOf(" $bare", "$bare ", "  $bare\n")) {
            assertEquals(
                "${spaced.replace("\n", "\\n")} scored differently",
                PassageRanker.score(passage(bare), terms, isRecent = false),
                PassageRanker.score(passage(spaced), terms, isRecent = false),
                0.0,
            )
        }
    }
}
