package com.benjaminissa.issareader.epub

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

// Ported from `SMILV3Tests.swift`: one class per Swift suite.

/**
 * A v3-aligned book reads like the v2 book it replaces.
 *
 * Built against `readalong-v3.epub`, which `make-readalong-fixture.py --v3`
 * writes the way Storyteller 3's aligner does: holes before and after
 * sentences that name the sentence's fragment, a sentence continued into the
 * next file, a two-file audio chapter behind chapter one, and clips that run
 * backwards inside one file.
 *
 * The timeline it parses to, one row per entry, for reading the tests below:
 *
 * ```
 *      0  ch01-s0  before-hole   track1   0–6.5
 *      1  ch01-s0                track1   6.5–10.75
 *      2  ch01-s0  after-hole    track1   10.75–17
 *      3  ch01-s1                track1   17–24.25      (s2 is a 1 ms filler)
 *      4  ch01-s3                track1   24.251–30.65  (s4 is a footnote)
 *      5  ch01-s5                track1   30.65–35.75
 *      6  ch01-s5  after-hole    track1   35.75–44      to the end of the file
 *      7  storyteller_audio_1-s0 bonus1   0–180         audio chapter, -a0
 *      8  storyteller_audio_1-s0 bonus2   0–150         audio chapter, -a1
 *      9  ch02-s0                track2a  0–5
 *     10  ch02-s1                track2a  5–9.75
 *     11  ch02-s1  -a1           track2b  0–3.5         continuation
 *     12  ch02-s2                track2b  3.5–8
 *     13  ch03-s0                track3   0–4
 *     14  ch03-s1                track3   14–19         heard after s2 and s3
 *     15  ch03-s2                track3   4–9
 *     16  ch03-s3                track3   9–14
 *     17  ch03-s4                track3   21–25         (19–21 is a gap)
 *     18  ch03-s4  after-hole    track3   25–33         the end of the book
 * ```
 */
class SmilV3Test {
    companion object {
        fun book(): EpubPackage = openFixture("readalong-v3")

        fun timeline(): SmilTimeline = SmilParser.timeline(book())

        const val track1 = "OEBPS/Audio/track1.mp3"
        const val track3 = "OEBPS/Audio/track3.mp3"
    }

    /** The fixture parses to the layout the tests are written against. */
    @Test
    fun layout() {
        val entries = timeline().entries
        assertEquals(
            listOf(
                "ch01-s0", "ch01-s0", "ch01-s0", "ch01-s1", "ch01-s3", "ch01-s5", "ch01-s5",
                "storyteller_audio_1-s0", "storyteller_audio_1-s0",
                "ch02-s0", "ch02-s1", "ch02-s1", "ch02-s2",
                "ch03-s0", "ch03-s1", "ch03-s2", "ch03-s3", "ch03-s4", "ch03-s4",
            ),
            entries.map { it.fragmentId },
        )
        assertEquals("OEBPS/storyteller-audio-1.xhtml", entries[7].textHref)
        assertEquals("OEBPS/Audio/bonus1.mp3", entries[7].audioHref)
        assertEquals("OEBPS/Audio/bonus2.mp3", entries[8].audioHref)
        assertEquals("OEBPS/Audio/track2b.mp3", entries[11].audioHref)
    }

    // Parsing

    /**
     * Holes and audio-chapter pars, and nothing else. The continuation at 11
     * carries its sentence's own state, and the words it is reading are real.
     */
    @Test
    fun audioOnlyFlags() {
        val entries = timeline().entries
        assertEquals(listOf(0, 2, 6, 7, 8, 18), entries.indices.filter { entries[it].isAudioOnly })
    }

    /**
     * `epub:type` is a token list; the aligner puts two tokens on its
     * word-granular seqs, and a par may carry more than one as well.
     */
    @Test
    fun typeIsATokenList() {
        val smil = """
            <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
              <body><seq>
                <par id="a" epub:type="storyteller:audio-only  extra">
                  <text src="c.xhtml#a"/><audio src="a.mp3" clipBegin="0s" clipEnd="1s"/>
                </par>
                <par id="b" epub:type="storyteller:audio-onlyish">
                  <text src="c.xhtml#b"/><audio src="a.mp3" clipBegin="1s" clipEnd="2s"/>
                </par>
                <par id="c">
                  <text src="c.xhtml#c"/><audio src="a.mp3" clipBegin="2s" clipEnd="3s"/>
                </par>
              </seq></body>
            </smil>
        """.trimIndent()
        val rows = SmilParser.parse(utf8(smil), overlayHref = "OEBPS/x.smil")
        assertEquals(listOf(true, false, false), rows.map { it.isAudioOnly })
    }

    // Sentence navigation

    /**
     * v2 folded a hole's seconds into the sentence it names, so being in the
     * hole is being in that sentence, and the next sentence is the one after.
     */
    @Test
    fun nextFromEveryPartOfASentence() {
        val timeline = timeline()
        val entries = timeline.entries
        for (index in listOf(0, 1, 2)) assertEquals("from entry $index", entries[3], timeline.entryAfter(entries[index]))
    }

    /** Next sentence steps over an after-hole and a whole audio chapter. */
    @Test
    fun nextSkipsTheAudioChapter() {
        val timeline = timeline()
        val entries = timeline.entries
        for (index in listOf(5, 6, 7, 8)) assertEquals("from entry $index", entries[9], timeline.entryAfter(entries[index]))
    }

    /** Next sentence steps over a continuation of the sentence it leaves. */
    @Test
    fun nextSkipsAContinuation() {
        val timeline = timeline()
        val entries = timeline.entries
        assertEquals(entries[12], timeline.entryAfter(entries[10]))
        assertEquals(entries[12], timeline.entryAfter(entries[11]))
    }

    /** There is no next sentence after the last one, hole or not. */
    @Test
    fun noNextAtTheEnd() {
        val timeline = timeline()
        val entries = timeline.entries
        assertNull(timeline.entryAfter(entries[17]))
        assertNull(timeline.entryAfter(entries[18]))
    }

    /**
     * A pin rather than a proof: resolving the continuation to its sentence, as
     * the timeline did before it told the two apart, lands here too. The test
     * below is the one that fails without it.
     */
    @Test
    fun previousFromAContinuation() {
        val timeline = timeline()
        val entries = timeline.entries
        assertEquals(entries[9], timeline.entryBefore(entries[11]))
    }

    /**
     * Walking back, a sentence that runs across files is met at its
     * continuation; landing there would start it part-way through.
     */
    @Test
    fun previousLandsOnTheSentenceNotItsContinuation() {
        val timeline = timeline()
        val entries = timeline.entries
        assertEquals(entries[10], timeline.entryBefore(entries[12]))
    }

    /** Previous sentence lands on the sentence, not the holes around it. */
    @Test
    fun previousSkipsHoles() {
        val timeline = timeline()
        val entries = timeline.entries
        // ch01-s1 back to ch01-s0's own par, past its after-hole and in front
        // of its before-hole.
        assertEquals(entries[1], timeline.entryBefore(entries[3]))
        // ch02-s0 back over the audio chapter and ch01-s5's after-hole.
        assertEquals(entries[5], timeline.entryBefore(entries[9]))
        assertNull(timeline.entryBefore(entries[0]))
        assertNull(timeline.entryBefore(entries[1]))
    }

    // The end of a file

    /**
     * The loop: ch01's file ends in ch01-s5's after-hole. What plays next is
     * the audio chapter, not the hole again and not chapter two.
     */
    @Test
    fun followingAFileEndingHole() {
        val timeline = timeline()
        val entries = timeline.entries
        val next = timeline.entryFollowing(entries[6])!!
        assertEquals(entries[7], next)
        assertEquals("storyteller_audio_1-s0", next.fragmentId)
        assertEquals("OEBPS/Audio/bonus1.mp3", next.audioHref)
        assertEquals(entries[8], timeline.entryFollowing(entries[7]))
        assertEquals(entries[9], timeline.entryFollowing(entries[8]))
    }

    /** The entry following is positional: a sentence's own hole and continuation count. */
    @Test
    fun followingIsPositional() {
        val timeline = timeline()
        val entries = timeline.entries
        assertEquals(entries[6], timeline.entryFollowing(entries[5]))
        assertEquals(entries[11], timeline.entryFollowing(entries[10]))
        assertNull("the end of the book", timeline.entryFollowing(entries[18]))
    }

    // Identity

    /**
     * A hole and its sentence share a fragment. Resolving the hole by that
     * fragment used to hand back the sentence, so everything positional about
     * it was measured from the wrong place.
     */
    @Test
    fun aHoleIsItsOwnPlace() {
        val timeline = timeline()
        val entries = timeline.entries
        val window = timeline.window(around = entries[2], before = 1, after = 1)!!
        assertEquals(listOf(entries[1], entries[2], entries[3]), window.entries)
        assertEquals(entries[2], window.entries[window.currentIndex])

        // And its chapter span is its own document's, the audio chapter's
        // included: 44 s of chapter one before it, five and a half minutes long.
        val hole = timeline.spanOfDocumentContaining(entries[6])!!
        val chapterOne = timeline.spanOfDocument("OEBPS/ch01.xhtml")!!
        assertEquals(chapterOne.start, hole.start, 0.0)
        assertEquals(chapterOne.duration, hole.duration, 0.0)
        val interlude = timeline.spanOfDocumentContaining(entries[8])!!
        assertTrue(abs(interlude.start - entries[6].cumulativeEnd) < 0.000_1)
        assertTrue(abs(interlude.duration - 330) < 0.000_1)
    }

    /**
     * Tap and seek resolve a fragment to the first of its sentence's entries.
     * For a sentence with a hole in front that is the hole, which is where v2's
     * clip for the same sentence began.
     */
    @Test
    fun fragmentsResolveToTheirFirstEntry() {
        val timeline = timeline()
        val entries = timeline.entries
        assertEquals(entries[0], timeline.entryForFragment("ch01-s0", "OEBPS/ch01.xhtml"))
        assertEquals(entries[7], timeline.entryForFragment("storyteller_audio_1-s0"))
    }

    // Clips that run backwards

    /** A run whose clips go backwards is looked up by what is playing, not by order. */
    @Test
    fun backwardsRun() {
        val timeline = timeline()
        val cases = listOf(
            2.0 to 13, 4.0 to 15, 6.0 to 15, 9.0 to 16, 11.0 to 16,
            14.0 to 14, 16.0 to 14, 22.0 to 17, 25.0 to 18, 30.0 to 18,
        )
        for ((time, expected) in cases) {
            assertEquals("at $time", timeline.entries[expected], timeline.entryInFile(track3, at = time))
        }
    }

    /**
     * Pins: the binary search this run used to get happens to answer both of
     * these right, and ch03's last entry is also the one that ends last.
     * `pastTheEndIsTheLatestEnding` is the case where it is not.
     */
    @Test
    fun backwardsRunGapAndEnd() {
        val timeline = timeline()
        assertNull("19–21 carries no clip", timeline.entryInFile(track3, at = 20.0))
        assertEquals(timeline.entries[18], timeline.entryInFile(track3, at = 40.0))
    }

    /** A run that ascends is searched as before, holes included. */
    @Test
    fun ascendingRunUnchanged() {
        val timeline = timeline()
        val entries = timeline.entries
        assertEquals(entries[0], timeline.entryInFile(track1, at = 3.0))
        assertEquals(entries[1], timeline.entryInFile(track1, at = 6.5))
        assertEquals(entries[2], timeline.entryInFile(track1, at = 12.0))
        assertNull("the dropped filler's millisecond is nobody's, as it was in v2", timeline.entryInFile(track1, at = 24.2505))
        assertEquals(entries[6], timeline.entryInFile(track1, at = 40.0))
        assertEquals(entries[6], timeline.entryInFile(track1, at = 99.0))
        assertEquals(entries[11], timeline.entryInFile("OEBPS/Audio/track2b.mp3", at = 1.0))
        assertEquals(entries[8], timeline.entryInFile("OEBPS/Audio/bonus2.mp3", at = 75.0))
    }

    /**
     * The overlap CTC actually leaves: a hole over audio that the next pars go
     * on to narrate. Every time in 10–20 is inside the hole too, and a binary
     * search stops there; the sentence being read began later.
     */
    @Test
    fun overlapPicksTheLatestStart() {
        val timeline = narration(
            Clip("a", "c.xhtml", "a.mp3", 0.0, 5.0, false),
            Clip("a", "c.xhtml", "a.mp3", 5.0, 20.0, true),
            Clip("b", "c.xhtml", "a.mp3", 10.0, 15.0, false),
            Clip("c", "c.xhtml", "a.mp3", 15.0, 20.0, false),
        )
        val entries = timeline.entries
        assertEquals(entries[0], timeline.entryInFile("a.mp3", at = 2.0))
        assertEquals(entries[1], timeline.entryInFile("a.mp3", at = 7.0))
        assertEquals(entries[2], timeline.entryInFile("a.mp3", at = 12.0))
        assertEquals(entries[3], timeline.entryInFile("a.mp3", at = 17.0))
        assertEquals("the later of the two that end last", entries[3], timeline.entryInFile("a.mp3", at = 25.0))
    }

    /**
     * The end of a run that goes backwards is where its latest clip ends, and
     * here that is not its last entry: "b" is heard last and ends at 15, "c" is
     * listed last and ends at 10. From 15 on the answer is "b", the sentence
     * just heard; taking the last entry answered "c", one read before it.
     */
    @Test
    fun pastTheEndIsTheLatestEnding() {
        val timeline = narration(
            Clip("a", "c.xhtml", "a.mp3", 0.0, 5.0, false),
            Clip("b", "c.xhtml", "a.mp3", 10.0, 15.0, false),
            Clip("c", "c.xhtml", "a.mp3", 5.0, 10.0, false),
        )
        val entries = timeline.entries
        assertEquals(entries[2], timeline.entryInFile("a.mp3", at = 7.0))
        assertEquals(entries[1], timeline.entryInFile("a.mp3", at = 12.0))
        assertEquals(entries[1], timeline.entryInFile("a.mp3", at = 15.0))
        assertEquals(entries[1], timeline.entryInFile("a.mp3", at = 20.0))
    }
}

/**
 * A word-granular v3 book: Storyteller 3 aligned at word granularity, which the
 * CLI offers and `SmilParser.parse` reads.
 *
 * The holes still name the *sentence* — `holePar` is handed the sentence's
 * fragment either way — but the pars between them are words, each under an id
 * of its own. So a sentence's before-hole and after-hole share a key with
 * entries of another key in between, and nothing about the key says where in
 * the book either of them is.
 *
 * The markup is the aligner's shape for a track that is one sentence with music
 * either side, a part title say: a before-hole where the file starts late, and
 * an after-hole on the tail, which runs to the end of the file.
 */
class SmilWordGranularV3Test {
    companion object {
        val chapterOne = """
            <?xml version="1.0" encoding="utf-8"?>
            <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0" epub:prefix="storyteller: https://storyteller-platform.gitlab.io/storyteller/docs/vocabulary">
              <body>
                <seq id="ch01_overlay" epub:textref="../ch01.xhtml" epub:type="chapter">
                  <par id="ch01-s0-before0" epub:type="storyteller:audio-only">
                    <text src="../ch01.xhtml#ch01-s0"/>
                    <audio src="../Audio/track1.mp3" clipBegin="0.000s" clipEnd="6.000s"/>
                  </par>
                  <seq id="ch01-s0" epub:type="text-range-small storyteller:matched" epub:textref="../ch01.xhtml#ch01-s0">
                    <par id="ch01-s0-w0" epub:type="storyteller:matched">
                      <text src="../ch01.xhtml#ch01-s0-w0"/>
                      <audio src="../Audio/track1.mp3" clipBegin="6.000s" clipEnd="7.000s"/>
                    </par>
                    <par id="ch01-s0-w1" epub:type="storyteller:matched">
                      <text src="../ch01.xhtml#ch01-s0-w1"/>
                      <audio src="../Audio/track1.mp3" clipBegin="7.000s" clipEnd="8.000s"/>
                    </par>
                  </seq>
                  <par id="ch01-s0-after0" epub:type="storyteller:audio-only">
                    <text src="../ch01.xhtml#ch01-s0"/>
                    <audio src="../Audio/track1.mp3" clipBegin="8.000s" clipEnd="20.000s"/>
                  </par>
                  <seq id="ch01-s1" epub:type="text-range-small storyteller:matched" epub:textref="../ch01.xhtml#ch01-s1">
                    <par id="ch01-s1-w0" epub:type="storyteller:matched">
                      <text src="../ch01.xhtml#ch01-s1-w0"/>
                      <audio src="../Audio/track2.mp3" clipBegin="0.000s" clipEnd="2.000s"/>
                    </par>
                    <par id="ch01-s1-w1" epub:type="storyteller:matched">
                      <text src="../ch01.xhtml#ch01-s1-w1"/>
                      <audio src="../Audio/track2.mp3" clipBegin="2.000s" clipEnd="5.000s"/>
                    </par>
                  </seq>
                </seq>
              </body>
            </smil>
        """.trimIndent()

        /**
         * ```
         *      0  ch01-s0     before-hole   track1  0–6
         *      1  ch01-s0-w0                track1  6–7
         *      2  ch01-s0-w1                track1  7–8
         *      3  ch01-s0     after-hole    track1  8–20   to the end of the file
         *      4  ch01-s1-w0                track2  0–2
         *      5  ch01-s1-w1                track2  2–5
         * ```
         */
        fun timeline(): SmilTimeline =
            SmilParser.timeline(SmilParser.parse(utf8(chapterOne), overlayHref = "OEBPS/MediaOverlays/ch01.smil"))
    }

    /** The holes name the sentence and the words between them do not. */
    @Test
    fun layout() {
        val entries = timeline().entries
        assertEquals(
            listOf("ch01-s0", "ch01-s0-w0", "ch01-s0-w1", "ch01-s0", "ch01-s1-w0", "ch01-s1-w1"),
            entries.map { it.fragmentId },
        )
        assertEquals(listOf(true, false, false, true, false, false), entries.map { it.isAudioOnly })
        assertEquals(setOf("OEBPS/ch01.xhtml"), entries.map { it.textHref }.toSet())
    }

    /**
     * The loop again, one granularity down. Resolved through its key, the
     * after-hole was the before-hole, the entry following it the sentence's
     * first word, and a file that ended in the hole played the sentence and the
     * music after it for ever.
     */
    @Test
    fun followingTheAfterHole() {
        val timeline = timeline()
        val entries = timeline.entries
        assertEquals(entries[4], timeline.entryFollowing(entries[3]))
        assertEquals(entries[1], timeline.entryFollowing(entries[0]))
    }

    /** Next from the after-hole is the next sentence, not back to the start of this one. */
    @Test
    fun nextFromTheAfterHole() {
        val timeline = timeline()
        val entries = timeline.entries
        assertEquals(entries[4], timeline.entryAfter(entries[3]))
    }

    /** The window around the after-hole is centred on the after-hole. */
    @Test
    fun windowAroundTheAfterHole() {
        val timeline = timeline()
        val entries = timeline.entries
        val window = timeline.window(around = entries[3], before = 1, after = 1)!!
        assertEquals(listOf(entries[2], entries[3], entries[4]), window.entries)
        assertEquals(entries[3], window.entries[window.currentIndex])
    }

    /**
     * The sentence's first entry is the hole in front of it, ahead of its words,
     * and it is where v2 began the same audio. `SmilSentenceKeyTest` has the
     * sentences with no hole in front, which resolve to a word.
     */
    @Test
    fun fragmentResolvesToTheBeforeHole() {
        val timeline = timeline()
        assertEquals(timeline.entries[0], timeline.entryForFragment("ch01-s0", "OEBPS/ch01.xhtml"))
    }
}

/**
 * Untexted audio at a chapter boundary, as Storyteller 3 plans it: the two
 * shapes its `planAudioChapters` actually makes of long untexted audio at a
 * chapter boundary, which the generated fixture does not reach — it pairs a
 * short tail hole *and* an untitled audio chapter at one boundary, where
 * holes.ts would plan them as one.
 *
 * With untitled bonus tracks, the tail of chapter one's file and both bonus
 * files are one run, over five minutes long, so the audio chapter opens in the
 * middle of chapter one's file. With titled ones, each track is a run of its
 * own and none reaches five minutes, so there is no audio chapter at all: the
 * last sentence keeps an after-hole in each of three files.
 */
class SmilPlannedHolesTest {
    companion object {
        const val chapterOne = "OEBPS/ch01.xhtml"
        const val chapterTwo = "OEBPS/ch02.xhtml"
        const val interlude = "OEBPS/storyteller-audio-1.xhtml"
        const val track1 = "OEBPS/Audio/track1.mp3"
        const val bonus1 = "OEBPS/Audio/bonus1.mp3"
        const val bonus2 = "OEBPS/Audio/bonus2.mp3"
        const val track2 = "OEBPS/Audio/track2a.mp3"

        /**
         * ```
         *      0  ch01-s0                 track1  0–30.65
         *      1  ch01-s5                 track1  30.65–35.75
         *      2  storyteller_audio_1-a0  track1  35.75–44   the interlude opens mid-file
         *      3  storyteller_audio_1-a1  bonus1  0–180
         *      4  storyteller_audio_1-a2  bonus2  0–150
         *      5  ch02-s0                 track2a 0–5
         * ```
         */
        fun untitledTracks() = narration(
            Clip("ch01-s0", chapterOne, track1, 0.0, 30.65, false),
            Clip("ch01-s5", chapterOne, track1, 30.65, 35.75, false),
            Clip("storyteller_audio_1-s0", interlude, track1, 35.75, 44.0, true),
            Clip("storyteller_audio_1-s0", interlude, bonus1, 0.0, 180.0, true),
            Clip("storyteller_audio_1-s0", interlude, bonus2, 0.0, 150.0, true),
            Clip("ch02-s0", chapterTwo, track2, 0.0, 5.0, false),
        )

        /**
         * ```
         *      0  ch01-s5                 track1  30.65–35.75
         *      1  ch01-s5  after0         track1  35.75–44
         *      2  ch01-s5  after1         bonus1  0–180
         *      3  ch01-s5  after2         bonus2  0–150
         *      4  ch02-s0                 track2a 0–5
         * ```
         */
        fun titledTracks() = narration(
            Clip("ch01-s5", chapterOne, track1, 30.65, 35.75, false),
            Clip("ch01-s5", chapterOne, track1, 35.75, 44.0, true),
            Clip("ch01-s5", chapterOne, bonus1, 0.0, 180.0, true),
            Clip("ch01-s5", chapterOne, bonus2, 0.0, 150.0, true),
            Clip("ch02-s0", chapterTwo, track2, 0.0, 5.0, false),
        )
    }

    /** An audio chapter that opens mid-file is found by the clock in that file. */
    @Test
    fun midFileInterludeByClock() {
        val timeline = untitledTracks()
        val entries = timeline.entries
        assertEquals(entries[1], timeline.entryInFile(track1, at = 33.0))
        assertEquals(entries[2], timeline.entryInFile(track1, at = 35.75))
        assertEquals(entries[2], timeline.entryInFile(track1, at = 40.0))
        assertEquals("past the end of the file", entries[2], timeline.entryInFile(track1, at = 99.0))
        assertEquals(entries[4], timeline.entryInFile(bonus2, at = 75.0))
    }

    /** Sentence steps pass over a mid-file audio chapter; the end of a file walks through it. */
    @Test
    fun midFileInterludeNavigation() {
        val timeline = untitledTracks()
        val entries = timeline.entries
        for (index in listOf(1, 2, 3, 4)) assertEquals("after $index", entries[5], timeline.entryAfter(entries[index]))
        assertEquals(entries[1], timeline.entryBefore(entries[5]))
        assertEquals(entries[1], timeline.entryBefore(entries[3]))
        for (index in 1..4) {
            assertEquals("following $index", entries[index + 1], timeline.entryFollowing(entries[index]))
        }
    }

    /** A mid-file audio chapter is a chapter span of its own. */
    @Test
    fun midFileInterludeSpan() {
        val timeline = untitledTracks()
        val entries = timeline.entries
        val chapterOneSpan = timeline.spanOfDocumentContaining(entries[1])!!
        assertEquals(0.0, chapterOneSpan.start, 0.0)
        assertTrue(abs(chapterOneSpan.duration - 35.75) < 0.000_1)
        val interludeSpan = timeline.spanOfDocumentContaining(entries[3])!!
        assertTrue(abs(interludeSpan.start - 35.75) < 0.000_1)
        assertTrue(abs(interludeSpan.duration - 338.25) < 0.000_1)
    }

    /** A sentence's after-holes in three files are walked by the end of each, and stepped over by next. */
    @Test
    fun afterHolesInThreeFiles() {
        val timeline = titledTracks()
        val entries = timeline.entries
        for (index in 0..3) {
            assertEquals("following $index", entries[index + 1], timeline.entryFollowing(entries[index]))
            assertEquals("after $index", entries[4], timeline.entryAfter(entries[index]))
        }
        assertNull(timeline.entryFollowing(entries[4]))
        assertEquals(entries[0], timeline.entryBefore(entries[4]))
        assertNull(timeline.entryBefore(entries[3]))
        assertEquals(entries[2], timeline.entryInFile(bonus1, at = 90.0))
    }

    /** Each of a sentence's after-holes is its own place in the book. */
    @Test
    fun afterHolesAreTheirOwnPlaces() {
        val timeline = titledTracks()
        val entries = timeline.entries
        for (index in 1..3) {
            val window = timeline.window(around = entries[index], before = 0, after = 0)!!
            assertEquals("window $index", listOf(entries[index]), window.entries)
        }
        val span = timeline.spanOfDocumentContaining(entries[3])!!
        assertEquals(0.0, span.start, 0.0)
        assertTrue(abs(span.duration - 343.35) < 0.000_1)
    }
}

/**
 * A v2-aligned book is unchanged: `readalong.epub` is v2 output, and v2 books
 * must behave exactly as they did before the timeline learned about v3.
 *
 * The list below was taken from the Swift implementation *before* that change,
 * so it pins the parse — every field, to the last bit of every sum — and the
 * navigation checks pin that a book with no audio-only entries and one entry
 * per fragment steps exactly as it always stepped: to the next and previous
 * entry by position.
 */
class SmilV2GoldenTest {
    companion object {
        fun timeline(): SmilTimeline = SmilParser.timeline(openFixture("readalong"))

        val golden: List<SmilEntry> = listOf(
            SmilEntry("ch01-s0", "OEBPS/ch01.xhtml", "OEBPS/Audio/track1.mp3", 0.0, 4.25, 4.25),
            SmilEntry("ch01-s1", "OEBPS/ch01.xhtml", "OEBPS/Audio/track1.mp3", 4.25, 11.5, 11.5),
            SmilEntry("ch01-s3", "OEBPS/ch01.xhtml", "OEBPS/Audio/track1.mp3", 11.501, 17.9, 17.899),
            SmilEntry("ch01-s5", "OEBPS/ch01.xhtml", "OEBPS/Audio/track1.mp3", 17.9, 23.0, 22.999000000000002),
            SmilEntry("ch02-s0", "OEBPS/ch02.xhtml", "OEBPS/Audio/track2.mp3", 0.0, 5.0, 27.999000000000002),
            SmilEntry("ch02-s1", "OEBPS/ch02.xhtml", "OEBPS/Audio/track2.mp3", 5.0, 9.75, 32.749),
        )
    }

    /** Every entry parses exactly as it did. */
    @Test
    fun entriesUnchanged() {
        val entries = timeline().entries
        assertEquals(golden, entries)
        assertTrue(entries.all { !it.isAudioOnly })
    }

    /** Next and previous sentence are the next and previous entry. */
    @Test
    fun navigationIsPositional() {
        val timeline = timeline()
        val entries = timeline.entries
        for (index in entries.indices) {
            val next = if (index + 1 < entries.size) entries[index + 1] else null
            val previous = if (index > 0) entries[index - 1] else null
            assertEquals("after $index", next, timeline.entryAfter(entries[index]))
            assertEquals("following $index", next, timeline.entryFollowing(entries[index]))
            assertEquals("before $index", previous, timeline.entryBefore(entries[index]))
        }
    }

    /** Every clip's midpoint finds that clip, and past a file's end finds its last. */
    @Test
    fun clipLookupUnchanged() {
        val timeline = timeline()
        for (entry in timeline.entries) {
            assertEquals(entry, timeline.entryInFile(entry.audioHref, at = (entry.start + entry.end) / 2))
        }
        assertEquals("ch01-s5", timeline.entryInFile("OEBPS/Audio/track1.mp3", at = 9_999.0)?.fragmentId)
        assertEquals("ch02-s1", timeline.entryInFile("OEBPS/Audio/track2.mp3", at = 9_999.0)?.fragmentId)
    }
}
