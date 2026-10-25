package com.benjaminissa.issareader.epub

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A `par` whose `<audio>` states no `clipEnd`.
 *
 * SMIL defines a missing `clipEnd` as "to the end of the media". The parser
 * read it as the clip's own start, so the par came out zero seconds long and
 * the minimum-duration filter dropped it as padding: the sentence never lit,
 * could not be tapped, and a whole-file par — an intro read over its heading, a
 * chapter aligned as one clip — took its file's audio out of the book.
 * Storyteller always writes `clipEnd`, so none of this reaches a book either
 * server aligned; a book from another toolchain can omit it. Ported from
 * `SMILOpenClipTests.swift`.
 */
class SmilOpenClipTest {
    companion object {
        const val overlay = "OEBPS/MediaOverlays/ch01.smil"
        const val chapter = "OEBPS/ch01.xhtml"

        /** `s1` and `s3` state no end; `s3` is the last clip of `a.mp3`. `s4` is a whole file, with neither end stated. */
        val smil = """
            <?xml version="1.0" encoding="utf-8"?>
            <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
              <body>
                <seq epub:textref="../ch01.xhtml" epub:type="chapter">
                  <par id="p1">
                    <text src="../ch01.xhtml#s1"/>
                    <audio src="../Audio/a.mp3" clipBegin="0s"/>
                  </par>
                  <par id="p2">
                    <text src="../ch01.xhtml#s2"/>
                    <audio src="../Audio/a.mp3" clipBegin="4.5s" clipEnd="9s"/>
                  </par>
                  <par id="p3">
                    <text src="../ch01.xhtml#s3"/>
                    <audio src="../Audio/a.mp3" clipBegin="9s"/>
                  </par>
                  <par id="p4">
                    <text src="../ch01.xhtml#s4"/>
                    <audio src="../Audio/b.mp3"/>
                  </par>
                </seq>
              </body>
            </smil>
        """.trimIndent()

        fun rows(): List<SmilParser.Row> = SmilParser.parse(utf8(smil), overlayHref = overlay)
    }

    /** A clip with no end runs on to the next clip in its file. */
    @Test
    fun runsToTheNextClip() {
        val timeline = SmilParser.timeline(rows())
        val first = timeline.entryForFragment("s1", chapter)
        assertNotNull("the par was dropped as a zero-length filler", first)
        assertEquals(0.0, first!!.start, 0.0)
        assertEquals("it ends where the next clip in a.mp3 begins", 4.5, first.end, 0.0)
        // And the one between keeps exactly what it stated.
        val second = timeline.entryForFragment("s2", chapter)!!
        assertEquals(4.5, second.start, 0.0)
        assertEquals(9.0, second.end, 0.0)
    }

    /**
     * The last clip of a file, and a par that is a whole file, run to the file's
     * end when its length is known.
     */
    @Test
    fun runsToTheFilesEnd() {
        val timeline = SmilParser.timeline(rows(), fileDurations = mapOf("OEBPS/Audio/a.mp3" to 20.0, "OEBPS/Audio/b.mp3" to 30.0))
        val third = timeline.entryForFragment("s3", chapter)!!
        assertEquals(9.0, third.start, 0.0)
        assertEquals(20.0, third.end, 0.0)
        val whole = timeline.entryForFragment("s4", chapter)!!
        assertEquals("OEBPS/Audio/b.mp3", whole.audioHref)
        assertEquals(0.0, whole.start, 0.0)
        assertEquals("the whole of b.mp3", 30.0, whole.end, 0.0)
        assertEquals("and the book clock carries every second of both files", 50.0, timeline.totalDuration, 0.0)
    }

    /**
     * With no length to hand — the reader parses the overlay before any audio is
     * extracted — the clip is still kept, so its file plays and its sentence
     * lights: it is the last clip of its file, which owns every time past its
     * start.
     */
    @Test
    fun keptWithoutALength() {
        val timeline = SmilParser.timeline(rows())
        val third = timeline.entryForFragment("s3", chapter)!!
        val whole = timeline.entryForFragment("s4", chapter)
        assertNotNull("a whole-file par took its file out of the book", whole)
        assertTrue(third.end > third.start)
        assertEquals("s3", timeline.entryInFile("OEBPS/Audio/a.mp3", at = 15.0)?.fragmentId)
        assertEquals(whole!!.fragmentId, timeline.entryInFile("OEBPS/Audio/b.mp3", at = 12.0)?.fragmentId)
    }

    /**
     * Storyteller writes `clipEnd` on every par, and its ~1 ms fillers must still
     * be dropped: nothing about a stated end changes.
     */
    @Test
    fun statedEndsAreUntouched() {
        val rows = SmilParser.parse(
            utf8(
                """
                    <smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><seq>
                      <par><text src="../ch01.xhtml#a"/><audio src="../Audio/a.mp3" clipBegin="0s" clipEnd="2s"/></par>
                      <par><text src="../ch01.xhtml#b"/><audio src="../Audio/a.mp3" clipBegin="2s" clipEnd="2.001s"/></par>
                      <par><text src="../ch01.xhtml#c"/><audio src="../Audio/a.mp3" clipBegin="2.001s" clipEnd="5s"/></par>
                    </seq></body></smil>
                """.trimIndent(),
            ),
            overlayHref = overlay,
        )
        assertTrue(rows.all { !it.isOpenEnded })
        val timeline = SmilParser.timeline(rows, fileDurations = mapOf("OEBPS/Audio/a.mp3" to 60.0))
        assertEquals("the filler is still dropped", listOf("a", "c"), timeline.entries.map { it.fragmentId })
        assertEquals("and no stated end moves for a file length", listOf(2.0, 5.0), timeline.entries.map { it.end })
    }
}
