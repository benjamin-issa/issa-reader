package com.benjaminissa.issareader.epub

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.seconds
import kotlin.time.measureTime

/**
 * What the timeline needs to know about clips with no stated end, and how fast
 * it can find out. Ported from `SMILOpenClipLengthTests.swift`.
 */
class SmilOpenClipLengthTest {
    companion object {
        const val chapter = "OEBPS/ch01.xhtml"

        fun row(id: String, audio: String, start: Double) = SmilParser.Row(
            fragmentId = id, textHref = chapter, audioHref = audio, start = start, end = start,
            isAudioOnly = false, sentenceId = null, isOpenEnded = true,
        )
    }

    /**
     * R-13. A file whose last clip states no end needs that file's length, and
     * only a reader that knows which files those are can measure them — once,
     * and not every file of a book that never needed it.
     */
    @Test
    fun filesNeedingLengthAreNamed() {
        val rows = listOf(
            row("s1", "OEBPS/Audio/a.mp3", start = 0.0),
            row("s2", "OEBPS/Audio/a.mp3", start = 4.0),
            row("s3", "OEBPS/Audio/b.mp3", start = 0.0),
        )
        val unmeasured = SmilParser.timeline(rows)
        assertEquals(setOf("OEBPS/Audio/a.mp3", "OEBPS/Audio/b.mp3"), unmeasured.filesNeedingLength)

        val half = SmilParser.timeline(rows, fileDurations = mapOf("OEBPS/Audio/a.mp3" to 9.0))
        assertEquals(setOf("OEBPS/Audio/b.mp3"), half.filesNeedingLength)

        val measured = SmilParser.timeline(rows, fileDurations = mapOf("OEBPS/Audio/a.mp3" to 9.0, "OEBPS/Audio/b.mp3" to 7.0))
        assertTrue(measured.filesNeedingLength.isEmpty())
        assertEquals(16.0, measured.totalDuration, 0.0)
    }

    /** Every book either Storyteller generation aligned states its ends, and asks for nothing. */
    @Test
    fun statedEndsNeedNothing() {
        val rows = listOf(
            SmilParser.Row(
                fragmentId = "s1", textHref = chapter, audioHref = "OEBPS/Audio/a.mp3",
                start = 0.0, end = 3.0, isAudioOnly = false, sentenceId = null, isOpenEnded = false,
            ),
        )
        assertTrue(SmilParser.timeline(rows).filesNeedingLength.isEmpty())
        assertTrue(SmilTimeline(emptyList()).filesNeedingLength.isEmpty())
    }

    /**
     * R-64. Each open clip found its successor by a linear scan of its file's
     * sorted starts: quadratic in the clips one file holds, on the main thread
     * at every open. Thirty thousand clipBegin-only clips in one long file is a
     * third-party book, not a contrived one.
     */
    @Test
    fun manyOpenClipsResolveQuickly() {
        val count = 30_000
        // Shuffled, so the resolution cannot lean on the rows arriving in
        // order: the starts are sorted once, per file, whatever the order.
        val rows = (0 until count).map { row("s$it", "OEBPS/Audio/long.mp3", start = it.toDouble()) }.shuffled()

        lateinit var resolved: List<SmilParser.Row>
        val elapsed = measureTime { resolved = SmilParser.resolvingOpenEnds(rows, fileDurations = emptyMap()) }

        assertTrue("resolving took $elapsed", elapsed < 1.seconds)
        val byId = resolved.associateBy { it.fragmentId }
        for (index in listOf(0, 1, 4_999, 29_998)) {
            val row = byId["s$index"]!!
            assertEquals("s$index ends where the next clip begins", (index + 1).toDouble(), row.end, 0.0)
        }
        val last = byId["s${count - 1}"]!!
        assertEquals((count - 1).toDouble() + SmilParser.openClipPlaceholder, last.end, 0.0)
    }

    /** Two clips that begin at the same moment: the next one *later* is the end, as the linear scan had it. */
    @Test
    fun equalStartsLookPastEachOther() {
        val rows = listOf(
            row("a", "OEBPS/Audio/a.mp3", start = 2.0),
            row("b", "OEBPS/Audio/a.mp3", start = 2.0),
            row("c", "OEBPS/Audio/a.mp3", start = 5.0),
        )
        val resolved = SmilParser.resolvingOpenEnds(rows, fileDurations = emptyMap())
        assertEquals(listOf(5.0, 5.0, 5 + SmilParser.openClipPlaceholder), resolved.map { it.end })
    }
}
