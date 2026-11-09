package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.epub.EpubPackage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private fun locator(
    fragments: List<String>? = null,
    progression: Double? = null,
    charOffset: Int? = null,
    text: ReadiumLocator.Text? = null,
) = ReadiumLocator(
    href = "ch01.xhtml", type = "application/xhtml+xml",
    locations = ReadiumLocator.Locations(fragments = fragments, progression = progression, charOffset = charOffset),
    text = text,
)

/**
 * Restoring a saved position. Ported from `LocatorAnchoringTests.swift`; the
 * case that needs a laid-out chapter (a saved page anchors on a fragment that
 * begins on it) is `:render-android`'s `SavedPageAnchorTest`.
 */
class LocatorAnchoringTest {
    private val text = "Chapter One. Alice was beginning to get very tired of sitting by her sister " +
        "on the bank, and of having nothing to do. So she considered in her own mind " +
        "whether the pleasure of making a daisy-chain would be worth the trouble. " +
        "Chapter One. There was nothing so very remarkable in that."

    /** The sentence id is the strongest anchor: it comes from the markup, so it does not move when the type size does. */
    @Test
    fun `A narrated fragment wins over everything else`() {
        val offset = LocatorAnchoring.characterOffset(
            locator(fragments = listOf("ch1-s3"), progression = 0.9, charOffset = 999), text,
            mapOf("ch1-s3" to TextRange(13, 20)),
        )
        assertEquals(13, offset)
    }

    /**
     * Page breaks fall mid-sentence far more often than not, so a position
     * saved at the top of a page names a sentence that began on the page
     * before. Returning that sentence's start put the reader there, the close
     * then saved *that* page, and the position walked back one page per open.
     */
    @Test
    fun `An offset inside the fragment refines it to the exact place`() {
        val ranges = mapOf("ch1-s2" to TextRange(13, 60))
        val inside = locator(fragments = listOf("ch1-s2"), progression = 0.2, charOffset = 40)
        assertEquals(40, LocatorAnchoring.characterOffset(inside, text, ranges))
        // An offset outside the sentence is from another rendering of the
        // text; the sentence keeps its authority.
        val stale = locator(fragments = listOf("ch1-s2"), progression = 0.2, charOffset = 200)
        assertEquals(13, LocatorAnchoring.characterOffset(stale, text, ranges))
    }

    /** A locator written before the reader changed font size still has to land on the same words, which only the quoted text can guarantee. */
    @Test
    fun `Remembered words re-anchor a position exactly`() {
        val offset = LocatorAnchoring.characterOffset(
            locator(progression = 0.5, charOffset = 4_000, text = ReadiumLocator.Text(highlight = "So she considered in her own mind")),
            text, emptyMap(),
        )
        assertEquals(text.indexOf("So she considered"), offset)
    }

    /** "Chapter One" appears twice here, as repeated phrases do in real books. Taking the first match would throw the reader back to the top. */
    @Test
    fun `A repeated phrase resolves to the occurrence nearest the recorded progress`() {
        val second = text.lastIndexOf("Chapter One")
        val offset = LocatorAnchoring.characterOffset(
            locator(
                progression = second.toDouble() / text.length,
                text = ReadiumLocator.Text(highlight = "Chapter One. There was nothing"),
            ),
            text, emptyMap(),
        )
        assertEquals(second, offset)
    }

    @Test
    fun `A quote that is no longer in the chapter falls back to the offset`() {
        val offset = LocatorAnchoring.characterOffset(
            locator(progression = 0.1, charOffset = 42, text = ReadiumLocator.Text(highlight = "words the publisher has since deleted entirely")),
            text, emptyMap(),
        )
        assertEquals(42, offset)
    }

    /** A much shorter chapter means a different revision of the file; a raw index into it would point somewhere arbitrary. */
    @Test
    fun `An offset past the end of the chapter is not used`() {
        val offset = LocatorAnchoring.characterOffset(locator(progression = 0.5, charOffset = 100_000), text, emptyMap())
        assertEquals((text.length * 0.5).toInt(), offset)
    }

    @Test
    fun `Quoting a position records the words at it, not the line breaks`() {
        assertEquals("First line second line", LocatorAnchoring.quote("First line\nsecond line", 0, length = 22)?.highlight)
        assertNull(LocatorAnchoring.quote("x", 5))
    }

    /** Positions written by the official client carry the manifest's absolute, percent-encoded href; the EPUB spine's is relative to the package. */
    @Test
    fun `Hrefs match across the forms different clients write`() {
        val locator = ReadiumLocator(href = "/OEBPS/text/chapter%2001.xhtml", type = "application/xhtml+xml")
        assertTrue(locator.matchesHref("text/chapter 01.xhtml"))
        assertTrue(locator.matchesHref("./text/chapter 01.xhtml"))
        assertTrue(locator.matchesHref("EPUB/text/chapter 01.xhtml#frag"))
        assertFalse(locator.matchesHref("text/chapter 02.xhtml"))
        // Not so tolerant that two chapters of the same name in different
        // directories collapse into one.
        assertFalse(locator.matchesHref("images/chapter 01.xhtml"))
    }

    /**
     * An omnibus with the same chapter names in two volumes: the last two
     * components cannot tell them apart, so the one the locator's own path
     * names has to win, not the first.
     */
    @Test
    fun `Hrefs that differ only above the last two components resolve to their own volume`() {
        val spine = listOf("vol1/text/ch01.xhtml", "vol1/text/ch02.xhtml", "vol2/text/ch01.xhtml", "vol2/text/ch02.xhtml")
        assertEquals(2, ReadiumLocator(href = "/OEBPS/vol2/text/ch01.xhtml", type = "application/xhtml+xml").bestMatch(spine))
        assertEquals(0, ReadiumLocator(href = "/OEBPS/vol1/text/ch01.xhtml", type = "application/xhtml+xml").bestMatch(spine))
        // Nothing to tell them apart by: the book's order, as before.
        val bare = ReadiumLocator(href = "text/ch02.xhtml", type = "application/xhtml+xml")
        assertEquals(1, bare.bestMatch(spine))
        assertEquals(listOf(1, 3), bare.rankedMatches(spine))
        // And none is still none.
        assertNull(ReadiumLocator(href = "text/ch09.xhtml", type = "application/xhtml+xml").bestMatch(spine))
    }
}

/**
 * Remembered words, found again in a chapter that has been rendered since.
 * Ported from `LocatorAnchoringTests.swift`'s `NearestOccurrenceTests`.
 *
 * Positions and highlights are both stored with their text: newlines folded to
 * spaces, written against one rendering of the chapter and read back against
 * another. The renderer of 2026-09-17 stopped keeping the stray space at the
 * start of every paragraph, so text stored before it has two spaces at every
 * paragraph break, text stored after it has one, and the chapter itself has a
 * newline — and a plain string search matched none of the three to each other.
 */
class NearestOccurrenceTest {
    private val paragraphs = listOf(
        "It was the best of times, it was the worst of times.",
        "He said nothing.",
        "She waited, and then the other one spoke at last, quietly.",
        "Nobody answered the door that night, or the next.",
    )

    /** The chapter as rendered now: blocks joined by a newline. */
    private val chapter = paragraphs.joinToString("\n")

    /** The same chapter as the old renderer laid it out: a stray space after every newline. */
    private val oldChapter = paragraphs.joinToString("\n ")

    /** A cut that split an emoji: a high half not followed by its low one, or a low half alone. */
    private fun hasLoneSurrogate(text: String): Boolean = text.indices.any { index ->
        val unit = text[index]
        (unit.isHighSurrogate() && (index + 1 >= text.length || !text[index + 1].isLowSurrogate())) ||
            (unit.isLowSurrogate() && (index == 0 || !text[index - 1].isHighSurrogate()))
    }

    /** What annotating and [LocatorAnchoring.quote] both do to text before storing it. */
    private fun stored(text: String): String = text.replace("\n", " ").trimmingWhitespaceAndNewlines()

    /**
     * A 64-unit highlight or a 32-unit context that ends or begins inside an
     * emoji stored a lone surrogate, which became U+FFFD on the Swift side —
     * and a quote with that in it is in no chapter, so the position fell back
     * to a raw offset.
     */
    @Test
    fun `a quote is never cut inside a surrogate pair`() {
        val emoji = String(Character.toChars(0x1F600))
        // The highlight's 64th unit is the first half of the emoji.
        val ending = "a".repeat(63) + emoji + " and the rest of the line"
        val head = LocatorAnchoring.quote(ending, 0)!!
        val headWords = head.highlight!!
        assertFalse(hasLoneSurrogate(headWords))
        assertTrue(headWords.startsWith("a".repeat(63) + emoji))

        // The context starts on the emoji's second half.
        val beginning = "a".repeat(10) + emoji + "b".repeat(40) + " tail"
        val tail = LocatorAnchoring.quote(beginning, 43)!!
        val before = tail.before!!
        assertFalse(hasLoneSurrogate(before))
        assertEquals("b".repeat(31), before)

        // And what was stored finds the place it came from.
        assertEquals(0, LocatorAnchoring.nearestOccurrence(headWords, ending, near = 0, before = head.before)?.location)
        assertEquals(43, LocatorAnchoring.nearestOccurrence(tail.highlight!!, beginning, near = 43, before = tail.before)?.location)
    }

    /** The case that never matched: a selection across a paragraph break, as a screen reader's whole-page highlight makes on almost every page. */
    @Test
    fun `an excerpt across a paragraph break finds the newline it was taken across`() {
        val found = LocatorAnchoring.nearestOccurrence(stored("worst of times.\nHe said"), chapter, near = null)!!
        assertEquals(chapter.indexOf("worst of times"), found.location)
        assertEquals("worst of times.\nHe said", chapter.substring(found.location, found.end))
    }

    /**
     * A mark made under the old renderer, read back under the new: two spaces
     * in the excerpt where the chapter now has one newline. The range found is
     * the words' extent *now*, a character shorter than the excerpt, so a
     * highlight painted from it does not run on into the next word.
     */
    @Test
    fun `an excerpt stored with the old double space matches the new single break`() {
        val oldOffset = oldChapter.indexOf("worst of times")
        val excerpt = stored(oldChapter.substring(oldOffset, oldOffset + 25))
        assertTrue("the fixture has to carry the old renderer's space", "  " in excerpt)
        val found = LocatorAnchoring.nearestOccurrence(excerpt, chapter, near = oldOffset)!!
        assertEquals(chapter.indexOf("worst of times"), found.location)
        assertEquals(excerpt.length - 1, found.length)
    }

    /**
     * A one-word highlight, made under the old renderer twelve paragraphs
     * down — so its stored offset is twelve characters late, and another "the"
     * sits nine characters after the marked one, nearer to that offset than
     * the mark itself. The words stored before it say which copy it was.
     */
    @Test
    fun `a short excerpt is placed by the words before it, not by the nearest copy`() {
        val lines = (1..12).map { "Line $it." } + "In the hall the dog slept, then the other woke."
        val chapter = lines.joinToString("\n")
        val old = lines.joinToString("\n ")
        val marked = old.indexOf("the hall")
        val truth = chapter.indexOf("the hall")
        assertEquals("one stray space per paragraph above", truth + 12, marked)
        val before = old.substring(marked - 32, marked).replace("\n", " ")

        assertEquals(TextRange(truth, 3), LocatorAnchoring.nearestOccurrence("the", chapter, near = marked, before = before))

        // What the nearest copy alone gives, which is the failure the context
        // is there for: the "the" of "the dog".
        assertEquals(chapter.indexOf("the dog"), LocatorAnchoring.nearestOccurrence("the", chapter, near = marked)?.location)
    }

    /** "the" is inside "then" and "other" here; a one-word excerpt is only ever found as a whole word. */
    @Test
    fun `a short excerpt is matched by whole words only`() {
        val then = chapter.indexOf("then")
        val other = chapter.indexOf("other") + 1
        for (near in listOf(then, other)) {
            val found = LocatorAnchoring.nearestOccurrence("the", chapter, near = near)!!
            assertTrue(found.location != then && found.location != other)
            assertEquals("a whole word, not the front of one", ' ', chapter[found.end])
        }
    }

    /** A short excerpt the chapter only holds inside longer words is not in the chapter at all. */
    @Test
    fun `a short excerpt found only inside longer words is not found`() {
        assertNull(LocatorAnchoring.nearestOccurrence("oth", chapter, near = 0))
    }

    @Test
    fun `an occurrence must begin inside the bounds it is given`() {
        val first = chapter.indexOf("of times")
        val second = chapter.lastIndexOf("of times")
        assertNotEquals(first, second)
        val found = LocatorAnchoring.nearestOccurrence("of times", chapter, near = first, startingWithin = TextRange(first + 1, 40))
        assertEquals(second, found?.location)
        assertNull(LocatorAnchoring.nearestOccurrence("It was the best", chapter, near = 0, startingWithin = TextRange(10, 20)))
    }

    @Test
    fun `nothing to look for, or nowhere to look, finds nothing`() {
        assertNull(LocatorAnchoring.nearestOccurrence("  \n ", chapter, near = 3))
        assertNull(LocatorAnchoring.nearestOccurrence("said", "", near = null))
    }

    /** Through the rung that restores a position: the quote of a place taken where the next sixty-four characters cross a paragraph break. */
    @Test
    fun `a quote across a newline re-anchors a position`() {
        val truth = chapter.indexOf("the worst of times")
        val quote = LocatorAnchoring.quote(chapter, truth)!!
        assertTrue("the quote has to cross the break", quote.highlight!!.contains("He said nothing"))
        // The recorded offset is from another rendering, a few characters out.
        val offset = LocatorAnchoring.characterOffset(
            locator(progression = truth.toDouble() / chapter.length, charOffset = truth + 3, text = quote), chapter, emptyMap(),
        )
        assertEquals(truth, offset)
    }

    /**
     * For a bookmark or a position on a page that opens mid-sentence: the
     * sentence id wins, and the recorded offset refines it — but an offset
     * recorded under the old renderer is a few characters out and still
     * inside a long sentence, so it was returned as it stood and could land a
     * page late. The words recorded there say where it is now.
     */
    @Test
    fun `a stale offset inside its sentence is corrected by the words recorded there`() {
        val sentence = paragraphs[2]
        val oldStart = oldChapter.indexOf(sentence)
        // A page break in the middle of the sentence, in the old rendering.
        val oldOffset = oldChapter.indexOf("the other one")
        val quote = LocatorAnchoring.quote(oldChapter, oldOffset)!!

        val newStart = chapter.indexOf(sentence)
        val ranges = mapOf("s2" to TextRange(newStart, sentence.length))
        val truth = chapter.indexOf("the other one")
        assertEquals("the same place in the sentence", truth - newStart, oldOffset - oldStart)
        assertTrue("and stale, but still inside it", oldOffset != truth && oldOffset in ranges.getValue("s2"))

        val offset = LocatorAnchoring.characterOffset(
            locator(fragments = listOf("s2"), charOffset = oldOffset, text = quote), chapter, ranges,
        )
        assertEquals(truth, offset)
    }

    /**
     * The same staleness a few characters further on: twelve paragraphs down,
     * the old offset of a place near the end of a short sentence is past the
     * sentence's end now, so it was set aside for the sentence's start — which
     * can be a page back. The words recorded at the place are still inside it.
     */
    @Test
    fun `a stale offset past the end of its sentence still finds the words inside it`() {
        val sentence = "A short one, then more."
        val lines = (1..12).map { "Line $it." } + listOf(sentence, "The next paragraph.")
        val chapter = lines.joinToString("\n")
        val old = lines.joinToString("\n ")
        val range = TextRange(chapter.indexOf(sentence), sentence.length)
        val oldOffset = old.indexOf("then more")
        val truth = chapter.indexOf("then more")
        assertEquals(truth + 12, oldOffset)
        assertTrue("past the sentence's end, as the chapter is now", oldOffset >= range.end)

        val offset = LocatorAnchoring.characterOffset(
            locator(fragments = listOf("s12"), charOffset = oldOffset, text = LocatorAnchoring.quote(old, oldOffset)),
            chapter, mapOf("s12" to range),
        )
        assertEquals(truth, offset)
    }

    /** Whitespace is matched by the run, ICU's `\s` and Swift's two more: a no-break space or a line separator in the chapter still separates words. */
    @Test
    fun `any run of whitespace matches any other`() {
        val chapter = "one\u00A0two\u2028three\u0085four"
        val found = LocatorAnchoring.nearestOccurrence("one two three four", chapter, near = null)
        assertEquals(TextRange(0, chapter.length), found)
    }
}

/**
 * Chapter labelling, which Gutenberg's EPUBs make harder than it looks: a
 * whole book in one spine file, chapters distinguished only by anchor. Ported
 * from `LocatorAnchoringTests.swift`'s `ChapterLabellingTests`.
 */
class ChapterLabellingTest {
    private val text = "a".repeat(100) + "Chapter One begins here. " + "b".repeat(100) +
        "Chapter Two begins here. " + "c".repeat(100)

    @Test
    fun `a hit is labelled with the chapter it falls in, not the file's first`() {
        val ranges = mapOf("c1" to TextRange(100, 24), "c2" to TextRange(225, 24))
        val nav = listOf(
            EpubPackage.NavPoint(title = "One", href = "book.xhtml", fragment = "c1"),
            EpubPackage.NavPoint(title = "Two", href = "book.xhtml", fragment = "c2"),
        )
        val hits = BookSearch.hits("begins here", text, 0, "The Whole Book", nav, ranges)
        assertEquals(2, hits.size)
        assertEquals("One", hits[0].chapterTitle)
        assertEquals("Two", hits[1].chapterTitle)
    }

    /** Before the first anchor there is no chapter yet — the file's own title is the honest answer, not the first chapter's. */
    @Test
    fun `text before the first anchor keeps the file's title`() {
        val hits = BookSearch.hits(
            "aaaa", text, 0, "Front Matter",
            listOf(EpubPackage.NavPoint(title = "One", href = "b.xhtml", fragment = "c1")),
            mapOf("c1" to TextRange(100, 24)),
        )
        assertEquals("Front Matter", hits.first().chapterTitle)
    }

    @Test
    fun `a search excerpt points at the match wherever it was clipped`() {
        val hit = BookSearch.hits("Chapter Two", text, 0, "Book").first()
        assertEquals("Chapter Two", hit.matchedText)
    }

    /**
     * The reader jumps to a hit by selecting the matched text: the selection
     * starts at `charOffset` and is sized on the text it is handed, so that
     * text must be the match alone — handing over the whole excerpt once
     * selected a sentence and a half of context.
     */
    @Test
    fun `the matched text sizes a selection covering exactly the match`() {
        val hit = BookSearch.hits("chapter two", text, 0, "Book").first()
        val matched = hit.matchedText
        assertEquals("Chapter Two", text.substring(hit.charOffset, hit.charOffset + matched.length))
    }

    /** A runaway match count on a common word would build a list nobody can use and hold the whole chapter in memory twice over. */
    @Test
    fun `matches are capped per chapter`() {
        assertEquals(10, BookSearch.hits("the", "the ".repeat(500), 0, "Book", limitPerChapter = 10).size)
    }

    /** Diacritic-insensitive, as Foundation's search is: the reader types "cafe" and finds "café", accent and all. */
    @Test
    fun `accents and case are folded, and the match covers the accented letters`() {
        val haystack = "At the Café we met; later, the cafe\u0301 closed."
        val hits = BookSearch.hits("CAFE", haystack, 0, "Book")
        assertEquals(2, hits.size)
        assertEquals("Café", haystack.substring(hits[0].charOffset, hits[0].charOffset + 4))
        assertEquals("cafe\u0301", haystack.substring(hits[1].charOffset, hits[1].charOffset + 5))
        // The excerpt marks the first match inside it, which for the second
        // hit is the first one, still in view: Foundation's search does the same.
        assertEquals("Caf\u00E9", hits[1].matchedText)
    }
}

/**
 * Where a tap lands. Ported from `LocatorAnchoringTests.swift`'s `TapZoneTests`.
 *
 * The old test compared a padded-frame x against the canvas width, so the back
 * zone was a margin narrower than intended and shifted inward — and over
 * narrated text it was unreachable altogether.
 */
class TapZoneTest {
    private fun zone(x: Double, width: Double, margin: Double) = ReaderTapZone.of(x, width, margin)

    @Test
    fun `the outer strips turn pages and the rest toggles chrome`() {
        val width = 300.0
        val margin = 24.0
        val full = width + margin * 2 // 348, so the strip is 24 + 44 = 68
        assertEquals(ReaderTapZone.BACK, zone(0.0, width, margin))
        assertEquals(ReaderTapZone.BACK, zone(40.0, width, margin))
        assertEquals(ReaderTapZone.MIDDLE, zone(full * 0.5, width, margin))
        assertEquals(ReaderTapZone.FORWARD, zone(full - 40, width, margin))
        assertEquals(ReaderTapZone.FORWARD, zone(full, width, margin))
    }

    /** The boundaries are measured against the frame the tap arrives in — the padded one — not the canvas inside it. */
    @Test
    fun `boundaries account for the page margin`() {
        val width = 300.0
        val margin = 24.0
        val full = width + margin * 2
        val strip = margin + 44
        assertEquals(ReaderTapZone.BACK, zone(strip - 1, width, margin))
        assertEquals(ReaderTapZone.MIDDLE, zone(strip + 1, width, margin))
        assertEquals(ReaderTapZone.MIDDLE, zone(full - strip - 1, width, margin))
        assertEquals(ReaderTapZone.FORWARD, zone(full - strip + 1, width, margin))
    }

    /**
     * The reason the strips are points and not a fraction. A quarter of a
     * tablet's width is 256pt — 232pt of it live text — so a reader aiming at a
     * sentence in the first third of the line turned the page instead.
     */
    @Test
    fun `the strip does not grow with the page`() {
        val margin = 24.0
        val phone = 393 - margin * 2
        val pad = 1024 - margin * 2
        assertEquals(ReaderTapZone.MIDDLE, zone(100.0, phone, margin))
        assertEquals(ReaderTapZone.MIDDLE, zone(100.0, pad, margin))
        assertEquals(ReaderTapZone.MIDDLE, zone(250.0, pad, margin))
        assertEquals(ReaderTapZone.BACK, zone(60.0, pad, margin))
    }

    /** A pop-up window is narrower than two strips plus a usable middle, so the fraction still caps them. */
    @Test
    fun `strips stay a quarter each on a narrow page`() {
        val margin = 24.0
        val width = 200 - margin * 2 // full = 200, so the cap is 50
        assertEquals(ReaderTapZone.BACK, zone(49.0, width, margin))
        assertEquals(ReaderTapZone.MIDDLE, zone(51.0, width, margin))
        assertEquals(ReaderTapZone.MIDDLE, zone(100.0, width, margin))
        assertEquals(ReaderTapZone.FORWARD, zone(151.0, width, margin))
    }

    @Test
    fun `a degenerate width does not turn pages`() {
        assertEquals(ReaderTapZone.MIDDLE, zone(10.0, 0.0, 0.0))
    }
}

/**
 * `progression` is decoded verbatim from the server, and the conversion to a
 * character index used to trap on the Swift side on anything non-finite or
 * huge — on every open of that book, with nothing the reader could do about
 * it. Ported from `HostileProgressionTests`.
 */
class HostileProgressionTest {
    @Test
    fun `non-finite and out-of-range values resolve or fall through, never trap`() {
        for (progression in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, 1e300, -1.0, 2.0, 0.5)) {
            val text = "abcdefghij".repeat(10)
            val offset = LocatorAnchoring.characterOffset(
                locator(progression = progression, text = ReadiumLocator.Text(highlight = "abcdefghijabcdefghij")), text, emptyMap(),
            )
            if (offset != null) {
                assertTrue("$progression", offset in 0 until 100)
            } else {
                assertFalse("a finite progression always names some character", progression.isFinite())
            }
        }
    }

    @Test
    fun `the offset a progression names is clamped into the text`() {
        assertEquals(9, LocatorAnchoring.offset(2.0, 10))
        assertEquals(0, LocatorAnchoring.offset(-1.0, 10))
        assertEquals(5, LocatorAnchoring.offset(0.5, 10))
        assertNull(LocatorAnchoring.offset(Double.NaN, 10))
        assertNull(LocatorAnchoring.offset(0.5, 0))
        assertNull(LocatorAnchoring.offset(null, 10))
        assertNotNull(LocatorAnchoring.offset(1e300, 10))
    }
}
