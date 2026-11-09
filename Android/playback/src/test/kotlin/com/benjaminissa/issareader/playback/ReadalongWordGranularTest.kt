package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.epub.SmilTimeline
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from `ReadalongWordGranularTests.swift`, over the scripted engine.

/**
 * The read-along on a book aligned word by word, which the CLI offers: each
 * sentence's words in a `text-range-small` seq that names the sentence, and a
 * sentence's holes beside it.
 *
 * Parsed from markup by the parser itself, so the timeline under the
 * coordinator is the one the app would build, and played over the v3 fixture's
 * own `track1.mp3`, which is all the player needs of it.
 *
 * ```
 *      0  ch01-s0-w0              0–1
 *      1  ch01-s0-w1              1–2
 *      2  ch01-s1-w0              2–3
 *      3  ch01-s1-w1              3–4
 *      4  ch01-s2-w0              4–5
 *      5  ch01-s2-w1              5–6
 *      6  ch01-s2     after-hole  6–10
 *      7  ch01-s3-w0              10–11
 *      8  ch01-s3-w1              11–12
 * ```
 */
class ReadalongWordGranularTest {
    private val markup = """
        <?xml version="1.0" encoding="utf-8"?>
        <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0" epub:prefix="storyteller: https://storyteller-platform.gitlab.io/storyteller/docs/vocabulary">
          <body>
            <seq id="ch01_overlay" epub:textref="../ch01.xhtml" epub:type="chapter">
              <seq id="ch01-s0" epub:type="text-range-small storyteller:matched" epub:textref="../ch01.xhtml#ch01-s0">
                <par id="ch01-s0-w0"><text src="../ch01.xhtml#ch01-s0-w0"/><audio src="../Audio/track1.mp3" clipBegin="0.000s" clipEnd="1.000s"/></par>
                <par id="ch01-s0-w1"><text src="../ch01.xhtml#ch01-s0-w1"/><audio src="../Audio/track1.mp3" clipBegin="1.000s" clipEnd="2.000s"/></par>
              </seq>
              <seq id="ch01-s1" epub:type="text-range-small storyteller:matched" epub:textref="../ch01.xhtml#ch01-s1">
                <par id="ch01-s1-w0"><text src="../ch01.xhtml#ch01-s1-w0"/><audio src="../Audio/track1.mp3" clipBegin="2.000s" clipEnd="3.000s"/></par>
                <par id="ch01-s1-w1"><text src="../ch01.xhtml#ch01-s1-w1"/><audio src="../Audio/track1.mp3" clipBegin="3.000s" clipEnd="4.000s"/></par>
              </seq>
              <seq id="ch01-s2" epub:type="text-range-small storyteller:matched" epub:textref="../ch01.xhtml#ch01-s2">
                <par id="ch01-s2-w0"><text src="../ch01.xhtml#ch01-s2-w0"/><audio src="../Audio/track1.mp3" clipBegin="4.000s" clipEnd="5.000s"/></par>
                <par id="ch01-s2-w1"><text src="../ch01.xhtml#ch01-s2-w1"/><audio src="../Audio/track1.mp3" clipBegin="5.000s" clipEnd="6.000s"/></par>
              </seq>
              <par id="ch01-s2-after0" epub:type="storyteller:audio-only">
                <text src="../ch01.xhtml#ch01-s2"/><audio src="../Audio/track1.mp3" clipBegin="6.000s" clipEnd="10.000s"/>
              </par>
              <seq id="ch01-s3" epub:type="text-range-small storyteller:matched" epub:textref="../ch01.xhtml#ch01-s3">
                <par id="ch01-s3-w0"><text src="../ch01.xhtml#ch01-s3-w0"/><audio src="../Audio/track1.mp3" clipBegin="10.000s" clipEnd="11.000s"/></par>
                <par id="ch01-s3-w1"><text src="../ch01.xhtml#ch01-s3-w1"/><audio src="../Audio/track1.mp3" clipBegin="11.000s" clipEnd="12.000s"/></par>
              </seq>
            </seq>
          </body>
        </smil>
    """.trimIndent()

    private fun timeline(): SmilTimeline =
        SmilParser.timeline(SmilParser.parse(markup.toByteArray(), "OEBPS/MediaOverlays/ch01.smil"))

    /**
     * The coordinator over the markup, with the clock and the end of the file
     * taken away: every command here plays from where it lands, and neither may
     * move the entry before the test looks at where it went.
     */
    private fun make(scope: CoroutineScope): Readalong {
        val timeline = timeline()
        check(
            timeline.entries.map { it.fragmentId } == listOf(
                "ch01-s0-w0", "ch01-s0-w1", "ch01-s1-w0", "ch01-s1-w1",
                "ch01-s2-w0", "ch01-s2-w1", "ch01-s2", "ch01-s3-w0", "ch01-s3-w1",
            ),
        )
        val readalong = makeReadalong(scope, timeline)
        readalong.subject.player.onTimeUpdate = null
        readalong.subject.player.onFinishedFile = null
        return readalong
    }

    /**
     * A tap between two of ch01-s2's words names the sentence. Its only hole is
     * after its words, and that hole was the one entry naming it, so the tap
     * played four seconds of music and none of the sentence.
     */
    @Test
    fun seekToASentencePlaysItsWords() = runTest {
        val readalong = make(backgroundScope)
        try {
            readalong.subject.seekToFragment("ch01-s2")
            assertEquals(readalong.timeline.entries[4], readalong.subject.activeEntry)
            assertEquals("ch01-s2-w0", readalong.subject.activeFragmentId)
        } finally {
            readalong.delete()
        }
    }

    /**
     * Three sentences back, from the first word of the fourth, is the first.
     * Stepping by fragment, three steps were three words, and the press landed
     * on the last word of ch01-s1.
     */
    @Test
    fun previousParagraph() = runTest {
        val readalong = make(backgroundScope)
        try {
            val entries = readalong.timeline.entries
            assertTrue(readalong.subject.prepare(entries[7]))
            readalong.subject.perform(PlaybackAction.PREVIOUS_PARAGRAPH, CommandMap())
            assertEquals(entries[0], readalong.subject.activeEntry)
        } finally {
            readalong.delete()
        }
    }

    /** A paragraph forward is three sentences forward, over the after-hole. */
    @Test
    fun nextParagraph() = runTest {
        val readalong = make(backgroundScope)
        try {
            val entries = readalong.timeline.entries
            assertTrue(readalong.subject.prepare(entries[0]))
            readalong.subject.perform(PlaybackAction.NEXT_PARAGRAPH, CommandMap())
            assertEquals(entries[7], readalong.subject.activeEntry)
        } finally {
            readalong.delete()
        }
    }

    /** Next and previous sentence move a sentence, from its first word. */
    @Test
    fun sentenceSteps() = runTest {
        val readalong = make(backgroundScope)
        try {
            val entries = readalong.timeline.entries
            val map = CommandMap()

            assertTrue(readalong.subject.prepare(entries[0]))
            readalong.subject.perform(PlaybackAction.NEXT_SENTENCE, map)
            assertEquals("the next sentence, not the next word", entries[2], readalong.subject.activeEntry)

            assertTrue(readalong.subject.prepare(entries[3]))
            readalong.subject.perform(PlaybackAction.PREVIOUS_SENTENCE, map)
            assertEquals("the sentence before, from its first word", entries[0], readalong.subject.activeEntry)
        } finally {
            readalong.delete()
        }
    }
}
