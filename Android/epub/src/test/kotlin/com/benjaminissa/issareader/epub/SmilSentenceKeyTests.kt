package com.benjaminissa.issareader.epub

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

// Ported from `SMILSentenceKeyTests.swift`: one class per Swift suite.

/**
 * A narration stated as the SMIL a word-granular alignment writes, parsed and
 * built into a timeline by the parser itself.
 *
 * The CLI's word mode nests each sentence's word pars in a `text-range-small`
 * seq whose `epub:textref` names the sentence; Storyteller 3 puts the
 * sentence's holes beside that seq, naming the sentence too. Every shape here
 * is one chapter, `OEBPS/ch01.xhtml`, read from `OEBPS/Audio/track1.mp3`.
 */
internal object WordGranularMarkup {
    const val chapter = "OEBPS/ch01.xhtml"

    fun timeline(body: String): SmilTimeline = SmilParser.timeline(rows(body))

    fun rows(body: String): List<SmilParser.Row> =
        SmilParser.parse(utf8(smil(body)), overlayHref = "OEBPS/MediaOverlays/ch01.smil")

    /** `body` inside the chapter seq, in a document that declares the storyteller vocabulary as 3.x does. */
    fun smil(body: String): String =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
            "<smil xmlns=\"http://www.w3.org/ns/SMIL\" xmlns:epub=\"http://www.idpf.org/2007/ops\" version=\"3.0\" " +
            "epub:prefix=\"storyteller: https://storyteller-platform.gitlab.io/storyteller/docs/vocabulary\">\n" +
            "  <body>\n    <seq id=\"ch01_overlay\" epub:textref=\"../ch01.xhtml\" epub:type=\"chapter\">\n" +
            "$body\n    </seq>\n  </body>\n</smil>"

    /** A sentence's words, in the seq that names it. */
    fun sentence(id: String, vararg words: String): String =
        "<seq id=\"$id\" epub:type=\"text-range-small storyteller:matched\" epub:textref=\"../ch01.xhtml#$id\">\n" +
            "${words.joinToString("\n")}\n</seq>"

    fun word(id: String, begin: Double, end: Double): String =
        "<par id=\"$id\" epub:type=\"storyteller:matched\">\n" +
            "  <text src=\"../ch01.xhtml#$id\"/>\n" +
            "  <audio src=\"../Audio/track1.mp3\" clipBegin=\"${begin}s\" clipEnd=\"${end}s\"/>\n</par>"

    /** A hole: audio with no words, naming the sentence it hangs off. */
    fun hole(sentence: String, begin: Double, end: Double): String =
        "<par id=\"$sentence-hole${begin.toInt()}\" epub:type=\"storyteller:audio-only\">\n" +
            "  <text src=\"../ch01.xhtml#$sentence\"/>\n" +
            "  <audio src=\"../Audio/track1.mp3\" clipBegin=\"${begin}s\" clipEnd=\"${end}s\"/>\n</par>"
}

/**
 * A word-granular sentence resolves to its first entry: its own fragment — what
 * a tap between two of its words, a selection, or the start of a page resolves
 * — reaches the sentence.
 *
 * Only its holes used to name it, first claim winning, so a sentence with a
 * hole only after its words resolved to that hole and played the music after
 * it, and a sentence with no holes resolved to nothing.
 */
class SmilSentenceKeyTest {
    private val markup = WordGranularMarkup

    /** A word records the sentence it is a word of, and nothing else does. */
    @Test
    fun sentenceIds() {
        val entries = SmilWordGranularV3Test.timeline().entries
        assertEquals(listOf(null, "ch01-s0", "ch01-s0", null, "ch01-s1", "ch01-s1"), entries.map { it.sentenceId })
    }

    /** A pin: the before-hole already named the sentence, first. */
    @Test
    fun beforeHoleWins() {
        val timeline = SmilWordGranularV3Test.timeline()
        assertEquals(timeline.entries[0], timeline.entryForFragment("ch01-s0", markup.chapter))
        assertEquals(timeline.entries[0], timeline.entryForFragment("ch01-s0"))
    }

    /**
     * A sentence with a hole only after its words resolves to its first word,
     * not the hole.
     *
     * ```
     *      0  ch01-s0-w0              0–1
     *      1  ch01-s0-w1              1–2
     *      2  ch01-s0     after-hole  2–14
     *      3  ch01-s1-w0              14–15
     *      4  ch01-s1-w1              15–16
     * ```
     */
    @Test
    fun afterHoleNeverWins() {
        val timeline = markup.timeline(
            listOf(
                markup.sentence("ch01-s0", markup.word("ch01-s0-w0", 0.0, 1.0), markup.word("ch01-s0-w1", 1.0, 2.0)),
                markup.hole("ch01-s0", 2.0, 14.0),
                markup.sentence("ch01-s1", markup.word("ch01-s1-w0", 14.0, 15.0), markup.word("ch01-s1-w1", 15.0, 16.0)),
            ).joinToString("\n"),
        )
        val entries = timeline.entries
        assertEquals(
            listOf("ch01-s0-w0", "ch01-s0-w1", "ch01-s0", "ch01-s1-w0", "ch01-s1-w1"),
            entries.map { it.fragmentId },
        )
        assertEquals(entries[0], timeline.entryForFragment("ch01-s0", markup.chapter))
        assertEquals("by id alone as well", entries[0], timeline.entryForFragment("ch01-s0"))
        assertEquals(0.0, timeline.bookTimeForFragment("ch01-s0", markup.chapter))
        // Its words and its hole are still each their own place.
        assertEquals(entries[1], timeline.entryForFragment("ch01-s0-w1", markup.chapter))
    }

    /** A sentence with no holes resolves to its first word. */
    @Test
    fun noHoles() {
        val timeline = SmilWordGranularV3Test.timeline()
        val entries = timeline.entries
        assertEquals(entries[4], timeline.entryForFragment("ch01-s1", markup.chapter))
        assertEquals("by id alone as well", entries[4], timeline.entryForFragment("ch01-s1"))
        assertEquals(entries[4].cumulativeEnd - entries[4].duration, timeline.bookTimeForFragment("ch01-s1", markup.chapter))
    }

    /** v2's CLI wrote the same seq with no storyteller vocabulary and no holes around it. */
    @Test
    fun v2CliMarkup() {
        val smil = """
            <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
              <body>
                <seq id="ch01_overlay" epub:textref="../ch01.xhtml" epub:type="chapter">
                  <seq id="s0" epub:type="text-range-small" epub:textref="../ch01.xhtml#s0">
                    <par id="s0-w0"><text src="../ch01.xhtml#s0-w0"/><audio src="../Audio/track1.mp3" clipBegin="0.000s" clipEnd="0.400s"/></par>
                    <par id="s0-w1"><text src="../ch01.xhtml#s0-w1"/><audio src="../Audio/track1.mp3" clipBegin="0.400s" clipEnd="0.900s"/></par>
                  </seq>
                </seq>
              </body>
            </smil>
        """.trimIndent()
        val rows = SmilParser.parse(utf8(smil), overlayHref = "OEBPS/MediaOverlays/ch01.smil")
        assertEquals(listOf("s0", "s0"), rows.map { it.sentenceId })
        val timeline = SmilParser.timeline(rows)
        assertEquals("s0-w0", timeline.entryForFragment("s0", markup.chapter)?.fragmentId)
    }

    /**
     * A block's seq names a paragraph, not a sentence, and the chapter's names a
     * document: neither is anybody's sentence. Inside a block, a sentence seq
     * still names its words'.
     */
    @Test
    fun onlyTheSentenceSeqCounts() {
        val rows = markup.rows(
            "<seq id=\"block0\" epub:type=\"text-range-large\" epub:textref=\"../ch01.xhtml#block0\">\n" +
                "  <par id=\"ch01-s0\"><text src=\"../ch01.xhtml#ch01-s0\"/><audio src=\"../Audio/track1.mp3\" clipBegin=\"0s\" clipEnd=\"2s\"/></par>\n" +
                "${markup.sentence("ch01-s1", markup.word("ch01-s1-w0", 2.0, 3.0))}\n</seq>",
        )
        assertEquals(listOf(null, "ch01-s1"), rows.map { it.sentenceId })
        val timeline = SmilParser.timeline(rows)
        assertNull(timeline.entryForFragment("block0", markup.chapter))
        assertNull(timeline.entryForFragment("block0"))
    }

    /** The unprefixed attribute spellings are read too. */
    @Test
    fun unprefixedSpelling() {
        val rows = markup.rows(
            "<seq type=\"text-range-small\" textref=\"../ch01.xhtml#ch01-s0\">\n${markup.word("ch01-s0-w0", 0.0, 1.0)}\n</seq>",
        )
        assertEquals(listOf("ch01-s0"), rows.map { it.sentenceId })
    }

    /**
     * Null rather than a fragment nobody has: a textref with no `#` names a
     * document, and a word the seq names itself is its own sentence already.
     */
    @Test
    fun degenerateSentenceSeqs() {
        val rows = markup.rows(
            "<seq epub:type=\"text-range-small\" epub:textref=\"../ch01.xhtml\">\n${markup.word("ch01-s0-w0", 0.0, 1.0)}\n</seq>\n" +
                "<seq epub:type=\"text-range-small\" epub:textref=\"../ch01.xhtml#ch01-s1\">\n${markup.word("ch01-s1", 1.0, 2.0)}\n</seq>",
        )
        assertEquals(listOf(null, null), rows.map { it.sentenceId })
    }
}

/**
 * A word-granular book steps by the sentence, not the word: next and previous
 * sentence at word granularity step by the sentence the words belong to.
 *
 * They stepped by fragment, and every word is a fragment of its own: "next
 * sentence" moved one word, "previous sentence" landed on the last word of the
 * sentence before and played on into its after-hole, and a paragraph was three
 * words.
 */
class SmilSentenceStepTest {
    private val markup = WordGranularMarkup

    /**
     * Next sentence from any part of a sentence is the next sentence's first word.
     *
     * ```
     *      0  ch01-s0     before-hole  0–6
     *      1  ch01-s0-w0               6–7
     *      2  ch01-s0-w1               7–8
     *      3  ch01-s0     after-hole   8–20
     *      4  ch01-s1-w0               0–2    track2
     *      5  ch01-s1-w1               2–5    track2
     * ```
     */
    @Test
    fun nextFromAnyPart() {
        val timeline = SmilWordGranularV3Test.timeline()
        val entries = timeline.entries
        for (index in 0..3) assertEquals("from entry $index", entries[4], timeline.entryAfter(entries[index]))
        assertNull(timeline.entryAfter(entries[4]))
        assertNull(timeline.entryAfter(entries[5]))
    }

    /** Previous sentence from any word is the sentence before, from its first word. */
    @Test
    fun previousFromAnyWord() {
        val timeline = SmilWordGranularV3Test.timeline()
        val entries = timeline.entries
        assertEquals(entries[1], timeline.entryBefore(entries[4]))
        assertEquals(entries[1], timeline.entryBefore(entries[5]))
        // Within the first sentence there is no sentence before.
        for (index in 0..3) assertNull("from entry $index", timeline.entryBefore(entries[index]))
    }

    /**
     * A chain of sentences is walked a sentence at a time both ways.
     *
     * ```
     *      0  ch01-s0     before-hole  0–6
     *      1  ch01-s0-w0               6–7
     *      2  ch01-s0-w1               7–8
     *      3  ch01-s1-w0               8–9
     *      4  ch01-s1-w1               9–10
     *      5  ch01-s1     after-hole   10–20
     *      6  ch01-s2-w0               20–21
     *      7  ch01-s2-w1               21–22
     * ```
     */
    @Test
    fun chain() {
        val timeline = markup.timeline(
            listOf(
                markup.hole("ch01-s0", 0.0, 6.0),
                markup.sentence("ch01-s0", markup.word("ch01-s0-w0", 6.0, 7.0), markup.word("ch01-s0-w1", 7.0, 8.0)),
                markup.sentence("ch01-s1", markup.word("ch01-s1-w0", 8.0, 9.0), markup.word("ch01-s1-w1", 9.0, 10.0)),
                markup.hole("ch01-s1", 10.0, 20.0),
                markup.sentence("ch01-s2", markup.word("ch01-s2-w0", 20.0, 21.0), markup.word("ch01-s2-w1", 21.0, 22.0)),
            ).joinToString("\n"),
        )
        val entries = timeline.entries
        assertEquals(
            listOf("ch01-s0", "ch01-s0-w0", "ch01-s0-w1", "ch01-s1-w0", "ch01-s1-w1", "ch01-s1", "ch01-s2-w0", "ch01-s2-w1"),
            entries.map { it.fragmentId },
        )

        val forward = ArrayList<SmilEntry>()
        var cursor = entries[1]
        while (true) {
            val next = timeline.entryAfter(cursor) ?: break
            forward.add(next)
            cursor = next
        }
        assertEquals(listOf(entries[3], entries[6]), forward)

        val backward = ArrayList<SmilEntry>()
        cursor = entries[7]
        while (true) {
            val previous = timeline.entryBefore(cursor) ?: break
            backward.add(previous)
            cursor = previous
        }
        assertEquals("each from its first word, the before-hole set aside", listOf(entries[3], entries[1]), backward)
        assertEquals("from the after-hole", entries[6], timeline.entryAfter(entries[5]))
    }
}
