package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.model.StoredPosition
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilTimeline
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale
import kotlin.math.abs

// Ported from `ListeningResumeTests.swift`.

/**
 * Resuming an audiobook, and refusing to guess when it cannot be done.
 *
 * The replay in the middle of this file is the 2026-09-09 report: a book whose
 * stored anchor named the EPUB's narration chunks against a manifest with one
 * track called after the upload. Every rung failed, and the old code said "no
 * audio anchor for this book yet" — which was not true, and sent whoever read
 * the log looking in the wrong place entirely.
 */
class ListeningResumeTest {
    private fun manifest(tracks: List<Pair<String, Double>>): AudiobookManifest = decodedManifest(tracks)

    /** The server's own upload: one ten-hour file named after the book. */
    private val original = listOf("The Outsider.mp3" to 36_000.0)

    /** The same audio as the EPUB carries it: numbered narration chunks. */
    private val chunks = listOf("OEBPS/Audio/00000-00085.mp3" to 600.0, "OEBPS/Audio/00086-00170.mp3" to 600.0)

    /** A position the audiobook engine wrote: the href is a track, the fraction is a fraction of the audio. */
    private fun audioLocator(href: String, progress: Double) = ReadiumLocator(
        href = href, type = "audio/mpeg", locations = ReadiumLocator.Locations(totalProgression = progress),
    )

    /**
     * A position the reader wrote: the href is a chapter, the fraction is a
     * fraction of the text, and the fragment names a narrated sentence.
     */
    private fun textLocator(href: String, progress: Double, fragment: String?) = ReadiumLocator(
        href = href, type = "application/xhtml+xml",
        locations = ReadiumLocator.Locations(fragments = fragment?.let { listOf(it) }, totalProgression = progress),
    )

    /**
     * A stored position as the server keeps it: a locator, and epoch
     * **milliseconds**. Spelled out rather than defaulted away, because the unit
     * is the whole trap — an anchor's `writtenAt` is epoch *seconds*, the two
     * fields are both `Double`, and both are named for the same idea.
     */
    private fun stored(locator: ReadiumLocator, writtenAtEpochSeconds: Double = 0.0) =
        StoredPosition(locator = locator, timestamp = writtenAtEpochSeconds * 1000)

    /**
     * Two volumes of one omnibus, each with a sentence called `s1`. A locator in
     * volume two must find volume two's, not the first document whose last two
     * path components happen to agree.
     */
    @Test
    fun aSharedSentenceIdResolvesInTheLocatorsOwnVolume() {
        val timeline = SmilTimeline(
            listOf(
                SmilEntry("s1", "vol1/text/ch01.xhtml", "Audio/a.mp3", 0.0, 5.0, 5.0),
                SmilEntry("s1", "vol2/text/ch01.xhtml", "Audio/b.mp3", 0.0, 5.0, 10.0),
            ),
        )
        val second = textLocator("/OEBPS/vol2/text/ch01.xhtml", 0.5, "s1")
        assertEquals("Audio/b.mp3", ListeningResume.entry("s1", second, timeline)?.audioHref)
        val first = textLocator("/OEBPS/vol1/text/ch01.xhtml", 0.5, "s1")
        assertEquals("Audio/a.mp3", ListeningResume.entry("s1", first, timeline)?.audioHref)
    }

    // The anchor, which is the rung that should answer

    /** An anchor naming a track wins. */
    @Test
    fun anAnchorNamingATrackWins() {
        val resolution = ListeningResume.resolve(
            anchor = AudioAnchor(chunks[1].first, 30.0, 1.0), stored = null, timeline = null, manifest = manifest(chunks),
        )
        assertEquals("the second chunk starts ten minutes in", 630.0, checkNotNull(resolution.bookTime), 0.0)
        assertEquals(ListeningResume.Reason.ANCHOR, resolution.reason)
        assertTrue(resolution.isTrusted)
    }

    /** An anchor outranks a stored audio position. */
    @Test
    fun anAnchorOutranksAStoredAudioPosition() {
        val resolution = ListeningResume.resolve(
            anchor = AudioAnchor(chunks[1].first, 30.0, 1.0),
            stored = stored(audioLocator(chunks[0].first, 0.05)),
            timeline = null, manifest = manifest(chunks),
        )
        assertEquals(630.0, checkNotNull(resolution.bookTime), 0.0)
        assertEquals(ListeningResume.Reason.ANCHOR, resolution.reason)
    }

    // How old the anchor is

    /**
     * The ordinary case, and the one that has to keep working: the audiobook
     * writes its position and then its anchor, a beat apart and in that order.
     * So an anchor a second younger than the position beside it is the *same*
     * moment of listening, not a stale one, and rung 1 still answers.
     */
    @Test
    fun anAnchorWrittenBesideItsOwnPositionStillAnswers() {
        val resolution = ListeningResume.resolve(
            anchor = AudioAnchor(chunks[1].first, 30.0, 1_757_000_001.0),
            stored = stored(audioLocator(chunks[0].first, 0.05), writtenAtEpochSeconds = 1_757_000_000.0),
            timeline = null, manifest = manifest(chunks),
        )
        assertEquals(630.0, checkNotNull(resolution.bookTime), 0.0)
        assertEquals(ListeningResume.Reason.ANCHOR, resolution.reason)
        assertTrue(resolution.isTrusted)
    }

    /**
     * The regression rung 1's age test exists for, on the audio clock. The
     * listener narrates to the second chunk, stops, and then listens on in the
     * car — which moves the stored position and leaves the anchor where the
     * narration ended. Trusting the anchor would resume where they were an hour
     * ago and write that over where they are now.
     */
    @Test
    fun aStoredAudioPositionWrittenSinceTheAnchorWins() {
        val resolution = ListeningResume.resolve(
            anchor = AudioAnchor(chunks[0].first, 30.0, 1_757_000_000.0),
            stored = stored(audioLocator(chunks[1].first, 0.9), writtenAtEpochSeconds = 1_757_003_600.0),
            timeline = null, manifest = manifest(chunks),
        )
        assertEquals(1200 * 0.9, checkNotNull(resolution.bookTime), 0.0)
        assertEquals(ListeningResume.Reason.AUDIO_POSITION, resolution.reason)
        assertTrue(resolution.isTrusted)
    }

    /**
     * The report this rung was added for, on the text clock. Narration plays to
     * 0.20 and stops; the reader relaunches and reads on in silence to 0.70,
     * which moves the position and never touches the anchor; they press Listen.
     * Rung 1 used to trust the anchor whatever its age, so the car resumed at
     * 0.20 and the fifteen-second writer put 0.20 over the 0.70.
     */
    @Test
    fun readingOnInSilenceOutranksTheAnchorTheNarrationLeft() {
        val (timeline, _) = readalongTimeline()
        val firstFileDuration = timeline.entries.last { it.audioHref == "OEBPS/Audio/track1.mp3" }.end
        val tracks = listOf("OEBPS/Audio/track1.mp3" to firstFileDuration, "OEBPS/Audio/track2.mp3" to 9.75)
        val chapterTwo = checkNotNull(timeline.entryForFragment("ch02-s0", "OEBPS/ch02.xhtml"))

        // Where the narration stopped: the first file, near its start.
        val resolution = ListeningResume.resolve(
            anchor = AudioAnchor("OEBPS/Audio/track1.mp3", 2.0, 1_757_000_000.0),
            // Where silent reading got to afterwards.
            stored = stored(textLocator("OEBPS/ch02.xhtml", 0.7, "ch02-s0"), writtenAtEpochSeconds = 1_757_003_600.0),
            timeline = timeline, manifest = manifest(tracks),
        )
        assertEquals(firstFileDuration + chapterTwo.start, checkNotNull(resolution.bookTime), 0.0)
        assertEquals(ListeningResume.Reason.READING_POSITION_VIA_OVERLAY, resolution.reason)
        assertTrue("the overlay makes a reading position exact", resolution.isTrusted)
    }

    /**
     * And the rung that catches the anchor when it loses. The same book on a
     * cold car launch: no reader is open, so there is no overlay to convert the
     * reading position through, and rung 3 cannot answer at all.
     *
     * Without this rung the losing anchor falls all the way to nothing, the
     * caller plays from progress 0, and a real place in the book — merely an old
     * one — becomes chapter one. So it plays from the anchor, untrusted: the hold
     * keeps that old place from being written over the newer one it lost to.
     */
    @Test
    fun anAnchorTheReadingLeftBehindIsAPlaceToStartNotToWriteFrom() {
        val resolution = ListeningResume.resolve(
            anchor = AudioAnchor(chunks[1].first, 30.0, 1_757_000_000.0),
            stored = stored(textLocator("OEBPS/ch41.xhtml", 0.7, "ch41-s12"), writtenAtEpochSeconds = 1_757_003_600.0),
            timeline = null, manifest = manifest(chunks),
        )
        assertEquals("the anchor's own place, which is still a real one", 630.0, checkNotNull(resolution.bookTime), 0.0)
        assertEquals(ListeningResume.Reason.ANCHOR_OLDER_THAN_POSITION, resolution.reason)
        assertFalse("and not where the reader got to, so nothing may be saved", resolution.isTrusted)
    }

    // The report, reproduced

    /**
     * The phone log of 2026-09-09. The anchor named
     * `OEBPS/Audio/00000-00085.mp3` — the EPUB's first narration chunk — and the
     * server's manifest has one track, `The Outsider.mp3`. The stored position
     * was the reader's, on the text clock, and the overlay was not in memory: a
     * cold car launch has no open reader. Every rung has to fail, and the reason
     * has to name the anchor rather than deny there is one.
     */
    @Test
    fun theOutsiderReplay_anAnchorNamingAChunkFallsThroughOnTheOriginalManifest() {
        val resolution = ListeningResume.resolve(
            anchor = AudioAnchor("OEBPS/Audio/00000-00085.mp3", 12.0, 1.0),
            stored = stored(textLocator("OEBPS/text/ch41.xhtml", 0.5363, "ch41-s12")),
            timeline = null, manifest = manifest(original),
        )
        assertNull("a text fraction must never be scaled by the audio", resolution.bookTime)
        assertEquals(ListeningResume.Reason.ANCHOR_NAMES_UNKNOWN_FILE, resolution.reason)
        assertFalse(resolution.isTrusted)
    }

    // Two clocks wearing the same field

    /**
     * The whole of the same narration, as the EPUB carries it: sixty chunks of
     * ten minutes, which is the ten hours the server serves as one file.
     */
    private val wholeChunks = (0 until 60).map { String.format(Locale.ROOT, "OEBPS/Audio/%05d.mp3", it) to 600.0 }

    /**
     * The one rung here that answers approximately, and a deliberate reversal:
     * this used to assert that a foreign audio position was refused outright.
     *
     * The two lists are the *same narration* cut up differently, so the
     * fraction lands within a chapter or two of the right place, and the thing
     * it was being refused in favour of was chapter one. The refusal was never
     * what protected the stored position anyway. That is the hold: `isTrusted` is
     * false here, so the audio clock stays held and the fifteen-second writer
     * cannot persist the guess until the listener names somewhere themselves.
     */
    @Test
    fun aStoredAudioPositionFromAnotherCutIsAPlaceToStart() {
        val resolution = ListeningResume.resolve(
            anchor = null, stored = stored(audioLocator("The Outsider.mp3", 0.5181)),
            timeline = null, manifest = manifest(wholeChunks),
        )
        val time = checkNotNull(resolution.bookTime)
        assertTrue(abs(time - 0.5181 * 36_000) < 0.001)
        assertEquals(ListeningResume.Reason.AUDIO_POSITION_FROM_ANOTHER_MANIFEST, resolution.reason)
        assertFalse("roughly right is a place to start, not a place to save", resolution.isTrusted)
    }

    /**
     * And the exact rung still outranks it: a position whose href names a track
     * in *this* manifest is a fraction of this manifest's own clock, with no
     * scaling between lists at all.
     */
    @Test
    fun aStoredAudioPositionOnThisManifestIsTrusted() {
        val resolution = ListeningResume.resolve(
            anchor = null, stored = stored(audioLocator("The Outsider.mp3", 0.5)),
            timeline = null, manifest = manifest(original),
        )
        assertEquals(18_000.0, checkNotNull(resolution.bookTime), 0.0)
        assertEquals(ListeningResume.Reason.AUDIO_POSITION, resolution.reason)
        assertTrue(resolution.isTrusted)
    }

    // The overlay bridge

    /**
     * The rung that makes a reading position resumable as audio, and the one
     * that needs a timeline handed to it — the caller's own reader may be
     * closed. Expected values come off the fixture's overlay rather than a
     * guess: chapter two's narration is the second file, so its first sentence
     * begins exactly where the first file ends.
     */
    @Test
    fun aReadingPositionConvertsThroughTheTimelineHandedIn() {
        val (timeline, _) = readalongTimeline()

        val first = timeline.entries.first { it.audioHref == "OEBPS/Audio/track1.mp3" }
        val firstFileDuration = timeline.entries.last { it.audioHref == "OEBPS/Audio/track1.mp3" }.end
        assertEquals("OEBPS/ch01.xhtml", first.textHref)

        val tracks = listOf("OEBPS/Audio/track1.mp3" to firstFileDuration, "OEBPS/Audio/track2.mp3" to 9.75)
        val chapterTwo = checkNotNull(timeline.entryForFragment("ch02-s0", "OEBPS/ch02.xhtml"))
        val resolution = ListeningResume.resolve(
            anchor = null, stored = stored(textLocator("OEBPS/ch02.xhtml", 0.6, "ch02-s0")),
            timeline = timeline, manifest = manifest(tracks),
        )
        assertEquals(firstFileDuration + chapterTwo.start, checkNotNull(resolution.bookTime), 0.0)
        assertEquals(ListeningResume.Reason.READING_POSITION_VIA_OVERLAY, resolution.reason)

        // And a sentence part-way into that file, so the assertion above cannot
        // pass on a zero offset alone.
        val later = checkNotNull(timeline.entryForFragment("ch02-s1", "OEBPS/ch02.xhtml"))
        val onward = ListeningResume.resolve(
            anchor = null, stored = stored(textLocator("OEBPS/ch02.xhtml", 0.8, "ch02-s1")),
            timeline = timeline, manifest = manifest(tracks),
        )
        assertEquals(firstFileDuration + later.start, checkNotNull(onward.bookTime), 0.0)
        assertTrue(later.start > 0)
    }

    /**
     * A book whose overlay numbers its sentences per chapter — legal, and what
     * any aligner other than Storyteller's writes — read on in chapter two by a
     * client that stores absolute hrefs, which is what the official one does.
     * The rung looked the locator's raw href up as a document key, missed, and
     * fell back to the first chapter using that id: chapter one, labelled exact,
     * so nothing held the audio clock and the next write put chapter one over a
     * reader two chapters on.
     */
    @Test
    fun aSharedSentenceIdResolvesInTheLocatorsOwnChapter() {
        val timeline = SmilTimeline(
            listOf(
                SmilEntry("sentence0", "OEBPS/ch01.xhtml", "OEBPS/Audio/a.mp3", 0.0, 5.0, 5.0),
                SmilEntry("sentence0", "OEBPS/ch02.xhtml", "OEBPS/Audio/b.mp3", 2.0, 7.0, 10.0),
            ),
        )
        val tracks = listOf("OEBPS/Audio/a.mp3" to 6.0, "OEBPS/Audio/b.mp3" to 8.0)

        val resolution = ListeningResume.resolve(
            anchor = null, stored = stored(textLocator("/OEBPS/ch02.xhtml", 0.6, "sentence0")),
            timeline = timeline, manifest = manifest(tracks),
        )
        assertEquals("chapter two's sentence, two seconds into the second file", 6.0 + 2, checkNotNull(resolution.bookTime), 0.0)
        assertEquals(ListeningResume.Reason.READING_POSITION_VIA_OVERLAY, resolution.reason)

        // A chapter the overlay does not narrate names no sentence at all.
        val elsewhere = ListeningResume.resolve(
            anchor = null, stored = stored(textLocator("/OEBPS/ch09.xhtml", 0.9, "sentence0")),
            timeline = timeline, manifest = manifest(tracks),
        )
        assertNotEquals(
            "an exact rung must not answer with another chapter's sentence",
            ListeningResume.Reason.READING_POSITION_VIA_OVERLAY, elsewhere.reason,
        )
        assertNull(elsewhere.bookTime)
    }

    /**
     * The cold car launch: nothing is open, so there is no overlay to convert
     * through. The text fraction is still not an answer.
     */
    @Test
    fun aReadingPositionWithoutATimelineResolvesToNothing() {
        val resolution = ListeningResume.resolve(
            anchor = null, stored = stored(textLocator("OEBPS/text/ch41.xhtml", 0.5363, "ch41-s12")),
            timeline = null, manifest = manifest(original),
        )
        assertNull(resolution.bookTime)
        assertEquals(ListeningResume.Reason.NO_ANCHOR_STORED, resolution.reason)
    }

    // Nothing at all

    /**
     * A book opened for the first time. Distinct from every failure above:
     * there is nothing to lose here, and the caller acts on that difference.
     */
    @Test
    fun nothingStoredIsSaidPlainly() {
        val resolution = ListeningResume.resolve(anchor = null, stored = null, timeline = null, manifest = manifest(original))
        assertNull(resolution.bookTime)
        assertEquals(ListeningResume.Reason.NO_STORED_POSITION, resolution.reason)
    }
}
