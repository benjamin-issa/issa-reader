package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.render.TextRange
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PassageChunkerTest {
    // Tiling

    @Test
    fun `passages tile the chapter with no gaps and no overlaps`() {
        val text = AskFixture.text(AskFixture.Spine.chapterI)
        val passages = PassageChunker.chunk(text, AskFixture.Spine.chapterI)
        assertTrue(passages.size > 3)
        // The straddling passage is cut to `boundary.charOffset - start`. A gap
        // anywhere in this sequence is a hole the reader's position can fall
        // into.
        assertEquals(0, passages.first().start)
        assertEquals(text.length, passages.last().end)
        for ((earlier, later) in passages.zipWithNext()) assertEquals(earlier.end, later.start)
    }

    /**
     * What `indexable` returns tiles `bookRange` itself — the range the
     * boundary truncation is measured inside. Every spine item of both
     * fixtures, because the markers are on different items in each.
     */
    @Test
    fun `indexable passages tile the book's own range, markers and all`() {
        for (book in listOf(AskFixture.alice, AskFixture.franklin)) {
            val epub = book.epubPackage()
            var straddles = 0
            for (spine in epub.spine.indices) {
                val text = runCatching { book.text(spine) }.getOrNull() ?: continue
                val range = PassageChunker.bookRange(text)
                // No navigation titles: dropping a contents list is a deliberate
                // hole, and it is the tiling either side of the *markers* that
                // this is about.
                val passages = PassageChunker.indexable(text, spine)
                val first = passages.firstOrNull() ?: continue
                val last = passages.last()

                assertEquals("spine $spine starts inside the book range", range.location, first.start)
                assertEquals("spine $spine stops short of the book range", range.end, last.end)
                for ((earlier, later) in passages.zipWithNext()) {
                    assertEquals("spine $spine has a hole at ${earlier.end}…${later.start}", earlier.end, later.start)
                }
                if (range.location != 0 || range.length != text.length) straddles += 1
            }
            assertTrue("no chapter of ${book.resource} carries a marker, so nothing was tested", straddles > 0)
        }
    }

    /** A clipped passage still says where its own characters are. */
    @Test
    fun `a clipped passage's characters are still the chapter's characters from its start`() {
        for (book in listOf(AskFixture.alice, AskFixture.franklin)) {
            val epub = book.epubPackage()
            for (spine in epub.spine.indices) {
                val text = runCatching { book.text(spine) }.getOrNull() ?: continue
                for (passage in PassageChunker.indexable(text, spine)) {
                    assertTrue(passage.start >= 0)
                    assertTrue(passage.end <= text.length)
                    assertTrue("only the trailing whitespace may be dropped", passage.text.length <= passage.end - passage.start)
                    val expected = text.substring(passage.start, passage.start + passage.text.length)
                    assertEquals("spine $spine passage ${passage.ordinal}", expected, passage.text)
                }
            }
        }
    }

    /**
     * *Franklin* has no separate footer spine item, so its END marker sits in
     * the middle of spine 10 and the passage carrying it carries the tail of
     * his chronology too. Clipping keeps it and drops only the notice.
     */
    @Test
    fun `the book text on the far side of an END marker survives`() {
        val text = AskFixture.franklin.text(10)
        val passages = PassageChunker.indexable(text, 10)
        val tail = passages.last()
        assertTrue(tail.text.contains("The Story of the Whistle"))
        assertTrue(tail.text.contains("Procuring Pleasant Dreams"))
        // And the notice itself is gone, which is what `bookRange` is for.
        assertFalse(passages.any { it.text.contains("END OF THE PROJECT GUTENBERG") })
        assertFalse(passages.any { it.text.contains("Updated editions will replace") })
    }

    @Test
    fun `a passage straddling a START marker keeps only what follows it`() {
        val text = AskFixture.alice.text(1)
        val range = PassageChunker.bookRange(text)
        val passages = PassageChunker.indexable(text, 1)
        val first = passages.first()
        assertEquals(range.location, first.start)
        assertFalse(first.text.contains("START OF THE PROJECT GUTENBERG"))
        assertFalse(passages.any { it.text.contains("Project Gutenberg eBook of") })
    }

    @Test
    fun `ordinals are the passage's own position, in order`() {
        val text = AskFixture.text(AskFixture.Spine.chapterII)
        val passages = PassageChunker.chunk(text, AskFixture.Spine.chapterII)
        assertEquals(passages.indices.toList(), passages.map { it.ordinal })
        assertTrue(passages.all { it.spineIndex == AskFixture.Spine.chapterII })
    }

    @Test
    fun `a passage's characters are the chapter's characters from its start`() {
        val text = AskFixture.text(AskFixture.Spine.chapterI)
        for (passage in PassageChunker.chunk(text, AskFixture.Spine.chapterI)) {
            // Not trimmed at the front, deliberately.
            val slice = text.substring(passage.start, passage.end)
            assertTrue(slice.startsWith(passage.text))
        }
    }

    // Limits

    @Test
    fun `no passage exceeds the maximum, except one that cannot be split`() {
        val text = AskFixture.text(AskFixture.Spine.chapterVI)
        val passages = PassageChunker.chunk(text, AskFixture.Spine.chapterVI)
        // A single sentence longer than the maximum has nowhere to be cut. What
        // must hold is that the splitter actually ran: the great majority fit.
        val oversized = passages.filter { it.words > PassageChunker.Limits.maximumWords }
        assertTrue(oversized.size.toDouble() / passages.size < 0.1)
    }

    @Test
    fun `a long paragraph is split at sentence ends, not mid-sentence`() {
        val sentence = "She ran down the passage and found a very small door behind a curtain. "
        val paragraph = sentence.repeat(12)
        val passages = PassageChunker.chunk(paragraph, 0)
        assertTrue(passages.size > 1)
        // Every piece but the last ends where a sentence ends.
        for (passage in passages.dropLast(1)) assertTrue(passage.text.trimmingWhitespaceAndNewlines().endsWith("."))
    }

    @Test
    fun `a runt is merged into its neighbour rather than retrieved alone`() {
        val body = "The garden was full of bright flowers and cool fountains. ".repeat(12)
        val text = "CHAPTER I\n\"Oh dear!\"\n$body"
        val passages = PassageChunker.chunk(text, 0)
        // A line of dialogue on its own tells the model nothing about who said
        // it, and a heading on its own is not evidence of anything.
        assertTrue(passages.all { it.words >= PassageChunker.Limits.minimumWords })
        assertTrue(passages[0].text.contains("CHAPTER I"))
    }

    @Test
    fun `a chapter opening on a heading keeps the heading with its first paragraph`() {
        val body = "Alice was beginning to get very tired of sitting by her sister. ".repeat(10)
        val passages = PassageChunker.chunk("CHAPTER I. Down the Rabbit-Hole\n$body", 0)
        assertEquals(1, passages.size)
        assertEquals(0, passages[0].start)
    }

    // Degenerate input

    @Test
    fun `empty and whitespace-only chapters produce nothing`() {
        assertTrue(PassageChunker.chunk("", 0).isEmpty())
        assertTrue(PassageChunker.chunk("\n\n  \n", 0).isEmpty())
    }

    @Test
    fun `words are counted by whitespace runs`() {
        assertEquals(0, PassageChunker.wordCount(""))
        assertEquals(0, PassageChunker.wordCount("   "))
        assertEquals(4, PassageChunker.wordCount("one two  three\nfour"))
    }

    // Navigation

    /** "Who is Alice?" asked at 4% cited "CHAPTER XII. Alice's Evidence": a contents table is not evidence. */
    @Test
    fun `the contents table is not indexed, and neither is Gutenberg's wrapper`() {
        val epub = AskFixture.epubPackage()
        val titles = epub.navigation.map { it.title }
        val dropped = ArrayList<Passage>()
        val keptSpines = HashSet<Int>()
        for (spine in epub.spine.indices) {
            val text = AskFixture.text(spine)
            val all = PassageChunker.chunk(text, spine)
            val kept = PassageChunker.indexable(text, spine, navigationTitles = titles)
            dropped.addAll(all.filter { it !in kept })
            if (kept.isNotEmpty()) keptSpines.add(spine)
        }
        // The contents table, which lives on Gutenberg's header page…
        assertTrue(dropped.any { it.spineIndex == 1 && it.text.contains("CHAPTER XII") })
        // …the legal notice and credits above the START marker on that page…
        assertTrue(dropped.any { it.spineIndex == 1 && it.text.contains("David Widger") })
        // …and the whole licence chapter below the END marker.
        assertFalse(1 in keptSpines)
        assertFalse((epub.spine.size - 1) in keptSpines)
        // Nothing else. Every chapter of the story keeps every passage it had.
        assertTrue(dropped.all { it.spineIndex == 1 || it.spineIndex == epub.spine.size - 1 })
        // 0 is the SVG cover wrapper, which renders as one object-replacement
        // character and stays.
        assertEquals((0..13).toSet() - setOf(1), keptSpines)
    }

    /** The gate that costs the most to get wrong: a shaped poem has the same shape as a contents table. */
    @Test
    fun `a shaped poem of equally short lines is kept`() {
        val epub = AskFixture.epubPackage()
        val titles = epub.navigation.map { it.title }
        // Chapter III, where "Fury said to a mouse" is set as a tail.
        val text = AskFixture.text(4)
        val kept = PassageChunker.indexable(text, 4, navigationTitles = titles)
        assertTrue(kept.any { it.text.contains("Fury said to") })
        assertEquals(PassageChunker.chunk(text, 4).size, kept.size)
    }

    @Test
    fun `with no navigation and no marker to go on, nothing is dropped`() {
        val text = AskFixture.text(AskFixture.Spine.chapterI)
        assertEquals(
            PassageChunker.chunk(text, AskFixture.Spine.chapterI).size,
            PassageChunker.indexable(text, AskFixture.Spine.chapterI).size,
        )
    }

    /** The credits line is the whole point: the transcribers were offered as suggestion chips. */
    @Test
    fun `what Gutenberg marks as its own is outside the book`() {
        val text = """
            The Project Gutenberg eBook of A Book
            Credits: David Widger
            *** START OF THE PROJECT GUTENBERG EBOOK A BOOK ***
            Alice was beginning to get very tired of sitting by her sister.
            *** END OF THE PROJECT GUTENBERG EBOOK A BOOK ***
            Updated editions will replace the previous one.
        """.trimIndent()
        val range = PassageChunker.bookRange(text)
        val inside = text.substring(range.location, range.end)
        assertTrue(inside.contains("Alice was beginning"))
        assertFalse(inside.contains("David Widger"))
        assertFalse(inside.contains("Updated editions"))
        // The older spelling, which is what most files on a shelf carry.
        assertTrue(PassageChunker.bookRange("a\n*** START OF THIS PROJECT GUTENBERG EBOOK X ***\nb").location > 0)
        // A book with no marker keeps all of itself.
        val plain = "Just a chapter of prose, with no transcriber's wrapper."
        assertEquals(TextRange(0, plain.length), PassageChunker.bookRange(plain))
    }

    @Test
    fun `a chapter heading above its own first paragraph is not a contents list`() {
        val body = "Alice was beginning to get very tired of sitting. ".repeat(12)
        assertFalse(
            PassageChunker.isNavigationList(
                "CHAPTER I.\nDown the Rabbit-Hole\n$body",
                titles = listOf(listOf("chapter", "i", "down", "the", "rabbit'hole")),
            ),
        )
    }

    @Test
    fun `a contents list whose titles are spelled differently is still caught`() {
        val titles = listOf(
            listOf("i", "ancestry", "and", "early", "youth", "in", "boston"),
            listOf("ii", "beginning", "life", "as", "a", "printer"),
            listOf("iii", "arrival", "in", "philadelphia"),
        )
        assertTrue(
            PassageChunker.isNavigationList(
                """
                I.  Ancestry and Early Life in Boston
                3
                II.  Beginning Life as a Printer
                21
                III.  Arrival in Philadelphia
                41
                """.trimIndent(),
                titles,
            ),
        )
    }
}
