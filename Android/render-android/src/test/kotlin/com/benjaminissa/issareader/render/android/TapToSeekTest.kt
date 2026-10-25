package com.benjaminissa.issareader.render.android

import com.benjaminissa.issareader.render.ReaderStyle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Tapping a sentence has to start the narration at that sentence. Ported from
 * `TapToSeekTests.swift`. The whole interaction rests on turning a point back
 * into a fragment id, so these exercise the round trip against a real aligned
 * chapter rather than trusting that the geometry lines up.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class TapToSeekTest {
    @Test
    fun `the point at the middle of a sentence resolves to that sentence`() {
        val chapter = readalongChapter()
        val layout = laidOut(chapter, 340.0, 560.0)
        var checked = 0
        for (id in chapter.fragmentRanges.keys.sorted()) {
            val page = layout.pageContainingFragment(id) ?: continue
            // The widest rectangle: a sentence that wraps has a short fragment
            // at either end where a midpoint may land on a neighbour.
            val rect = layout.highlightRects(id, page).maxByOrNull { it.width } ?: continue
            if (rect.width <= 30) continue
            assertEquals("tapping the middle of $id should resolve to $id", id, layout.fragmentId(rect.midX, rect.midY, page))
            checked += 1
            if (checked >= 12) break
        }
        assertTrue("the fixture should offer several sentences to tap", checked >= 4)
    }

    /**
     * The second line of a wrapped paragraph is where an off-by-a-line error
     * in the hit test shows up: the index would come back short by a whole
     * line.
     */
    @Test
    fun `a tap on a later line of a paragraph does not resolve to the first`() {
        val layout = laidOut(readalongChapter(), 260.0, 560.0)
        val page = layout.pages.first()
        val high = layout.characterIndex(40.0, 30.0, page)!!
        val low = layout.characterIndex(40.0, 300.0, page)!!
        assertTrue(low > high)
        assertTrue(high in page.characterRange)
        assertTrue(low in page.characterRange)
    }

    @Test
    fun `a tap in the margin below the text does not crash or wrap around`() {
        val layout = laidOut(readalongChapter(), 340.0, 560.0)
        val page = layout.pages.first()
        layout.characterIndex(10.0, 559.0, page)?.let { assertTrue(it >= page.characterRange.location) }
    }
}

/**
 * Tapping inside a long paragraph. Ported from `TapToSeekTests.swift`'s
 * `LongParagraphTapTests`: several sentences in one paragraph, with a face and
 * a fragment id on each and no paragraph style at all.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class LongParagraphTapTest {
    private val sentences = listOf(
        "This ebook is for the use of anyone anywhere in the United States and most other parts of the world at no cost and with almost no restrictions whatsoever. ",
        "You may copy it, give it away or re-use it under the terms of the Project Gutenberg License included with this ebook or online at www.gutenberg.org. ",
        "If you are not located in the United States, you will have to check the laws of the country where you are located before using this eBook.",
    )

    private fun layout() = laidOut(handBuiltSentences(sentences) { "s${it + 1}" }, 320.0, 900.0)

    @Test
    fun `every sentence in one wrapped paragraph resolves to itself`() {
        val layout = layout()
        val page = layout.pages.first()
        assertEquals("the whole paragraph should fit on one page", 1, layout.pages.size)
        for (id in layout.fragmentRanges.keys.sorted()) {
            val rect = layout.highlightRects(id, page).maxByOrNull { it.width }!!
            assertEquals("tapping $id at ${rect.midX}, ${rect.midY} resolved elsewhere", id, layout.fragmentId(rect.midX, rect.midY, page))
        }
    }

    /** Walking down the paragraph line by line must produce indices that only ever move forward. */
    @Test
    fun `indices increase monotonically down a wrapped paragraph`() {
        val layout = layout()
        val page = layout.pages.first()
        var previous = -1
        var y = 6.0
        while (y < 200.0) {
            layout.characterIndex(160.0, y, page)?.let { index ->
                assertTrue("index went backwards at y=$y", index >= previous)
                previous = index
            }
            y += 8.0
        }
        assertTrue("walking the paragraph should reach well into it", previous > 100)
    }
}

/**
 * The shape real books actually have. Ported from `TapToSeekTests.swift`'s
 * `RealProseTapTests`: ids on inline spans and none on the paragraph, exactly
 * as Storyteller writes it, under a full paragraph style — one paragraph
 * holding six to ten lines and several narrated sentences.
 *
 * The property asserted is the one that cannot be argued with: tapping and
 * highlighting read the *same* fragment table in opposite directions, so they
 * must be mutual inverses. Where the highlight draws a sentence, a tap there
 * must name that sentence.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class RealProseTapTest {
    companion object {
        val sentences = listOf(
            "They had been flying apart, but they huddled close to Peter now. ",
            "His careless manner had gone at last, his eyes were sparkling, and a tingle went through them every time they touched his body. ",
            "They were now over the fearsome island, flying so low that sometimes a tree grazed their feet. ",
            "Nothing horrid was visible in the air, yet their progress had become slow and laboured. ",
            "Sometimes they hung in the air until Peter had beaten on it with his fists. ",
        )

        fun chapter(style: ReaderStyle, width: Double = 300.0): ChapterLayout {
            val body = StringBuilder()
            var n = 0
            repeat(5) {
                body.append("<p>")
                for (sentence in sentences) body.append("<span id=\"s${n++}\">$sentence</span>")
                body.append("</p>")
            }
            // An indented block carries a head indent and a first-line indent,
            // which the line search also has to survive.
            body.append("<blockquote><p>")
            for (sentence in sentences.take(3)) body.append("<span id=\"q${n++}\">$sentence</span>")
            body.append("</p></blockquote>")
            val xhtml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><html><body>$body</body></html>"
            return laidOut(parse(xhtml, style = style, baseHref = "chapter.xhtml"), width, 2000.0, style)
        }

        /**
         * Every rectangle the highlight would draw, tapped at its centre —
         * deliberately not a sample. A wrapped sentence leaves a sliver at
         * either end of a line where a midpoint genuinely belongs to a
         * neighbour; every fragment still contributes its full-width lines.
         */
        fun audit(layout: ChapterLayout): Triple<Int, Int, List<String>> {
            var checked = 0
            var wrong = 0
            val missed = ArrayList<String>()
            for (id in layout.fragmentRanges.keys.sorted()) {
                val page = layout.pageContainingFragment(id) ?: continue
                var sawOne = false
                for (rect in layout.highlightRects(id, page)) {
                    if (rect.width < 16 || rect.height < 4) continue
                    sawOne = true
                    checked += 1
                    if (layout.fragmentId(rect.midX, rect.midY, page) != id) wrong += 1
                }
                if (!sawOne) missed.add(id)
            }
            return Triple(checked, wrong, missed)
        }
    }

    @Test
    fun `every point the highlight covers resolves back to its own sentence`() {
        for (spacing in ReaderStyle.LineSpacing.entries) {
            val (checked, wrong, _) = audit(chapter(ReaderStyle(lineSpacing = spacing)))
            assertTrue("$spacing: the fixture should offer plenty of points; got $checked", checked > 60)
            assertEquals("$spacing: $wrong of $checked points resolved to the wrong sentence or to nothing", 0, wrong)
        }
    }

    @Test
    fun `justified text, where hyphenation and stretched spaces move every line`() {
        val (checked, wrong, _) = audit(chapter(ReaderStyle(justification = ReaderStyle.Justification.ALWAYS)))
        assertEquals("$wrong of $checked points resolved elsewhere when justified", 0, wrong)
    }

    @Test
    fun `every sentence is reachable, not merely most of them`() {
        val (_, _, missed) = audit(chapter(ReaderStyle()))
        assertTrue("no rectangle wide enough to tap for: ${missed.sorted()}", missed.isEmpty())
    }

    /** The reported symptom: the sentences that kept working were the ones on a paragraph's opening line. */
    @Test
    fun `a tap on the last line of a long paragraph names the sentence there`() {
        val layout = chapter(ReaderStyle())
        val page = layout.pages.first()
        val rect = layout.highlightRects("s4", page).maxByOrNull { it.width }!!
        assertEquals("s4", layout.fragmentId(rect.midX, rect.midY, page))
    }
}

/**
 * Which id a tap is allowed to answer with, and what happens when the point
 * owns none. Ported from `TapToSeekTests.swift`'s `UsableFragmentTests`.
 *
 * Element ids are not all sentences. The characters between and around
 * sentences — a paragraph's trailing newline, the space after a short last
 * line — frequently belong to *no* narrated fragment at all, and answering
 * "nothing" there is a silent refusal.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class UsableFragmentTest {
    /** A publisher's shape rather than Gutenberg's: the paragraph carries an id of its own, wrapping the sentence spans. */
    private fun chapter(): ChapterLayout {
        val spans = RealProseTapTest.sentences.withIndex().joinToString("") { (i, s) -> "<span id=\"s$i\">$s</span>" }
        val xhtml = "<html><body><p id=\"para1\">$spans</p><p id=\"para2\"><span id=\"s9\">A short closing line.</span></p></body></html>"
        return laidOut(parse(xhtml), 300.0, 2000.0)
    }

    private val narrated: (String) -> Boolean = { it.startsWith("s") }

    @Test
    fun `a paragraph wrapper cannot shadow the sentence inside it`() {
        val layout = chapter()
        val page = layout.pages.first()
        assertTrue(layout.fragmentRanges["para1"] != null)
        var checked = 0
        for (id in layout.fragmentRanges.keys.sorted().filter(narrated)) {
            for (rect in layout.highlightRects(id, page).filter { it.width >= 16 }) {
                checked += 1
                assertEquals(id, layout.fragmentId(rect.midX, rect.midY, page, narrated))
            }
        }
        assertTrue(checked > 4)
    }

    @Test
    fun `a tap past the end of a short last line still finds that line's sentence`() {
        val layout = chapter()
        val page = layout.pages.first()
        val rect = layout.highlightRects("s9", page).first()
        assertEquals("a tap on the same line as a sentence should reach it", "s9", layout.fragmentId(295.0, rect.midY, page, narrated))
    }

    @Test
    fun `nothing usable on the page means nothing, rather than a wrong answer`() {
        val layout = chapter()
        val page = layout.pages.first()
        val rect = layout.highlightRects("s0", page).first()
        assertNull(layout.fragmentId(rect.midX, rect.midY, page) { false })
    }

    @Test
    fun `the same point always resolves to the same id`() {
        val layout = chapter()
        val page = layout.pages.first()
        val rect = layout.highlightRects("s2", page).first()
        val answers = (0 until 40).map { layout.fragmentId(rect.midX, rect.midY, page, narrated) ?: "nil" }.toSet()
        assertEquals("resolved to ${answers.sorted()} across repeated calls", 1, answers.size)
    }

    @Test
    fun `the nearest answer never reaches off the page the reader is looking at`() {
        val body = StringBuilder()
        var n = 0
        repeat(8) {
            body.append("<p id=\"p$n\">")
            for (sentence in RealProseTapTest.sentences) body.append("<span id=\"s${n++}\">$sentence</span>")
            body.append("</p>")
        }
        val layout = laidOut(parse("<html><body>$body</body></html>"), 300.0, 320.0)
        assertTrue("the fixture should paginate", layout.pages.size > 2)
        for (page in layout.pages.drop(1).take(3)) {
            // Bottom-right of the page: past the end of the last line, which is
            // exactly where the enclosing search comes up empty.
            val id = layout.fragmentId(295.0, page.height - 4, page, narrated) ?: continue
            val range = layout.fragmentRanges.getValue(id)
            assertTrue("$id is not on page ${page.index}", range.intersection(page.characterRange).length > 0)
        }
    }

    @Test
    fun `the unfiltered form still answers with the innermost id`() {
        val layout = chapter()
        val page = layout.pages.first()
        val rect = layout.highlightRects("s1", page).first()
        assertEquals("s1", layout.fragmentId(rect.midX, rect.midY, page))
    }
}
