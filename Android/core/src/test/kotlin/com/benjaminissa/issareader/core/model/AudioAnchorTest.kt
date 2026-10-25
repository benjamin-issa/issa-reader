package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.instantOfEpochSeconds
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.withTemporaryDirectory
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The bridge between the two clocks one book is played on. Ported from
 * `AudioAnchorTests.swift`.
 *
 * The app has two playback engines for a read-along: the read-along
 * coordinator, driven by the EPUB's media overlay, and the audiobook
 * coordinator, driven by the server's track list. They keep different
 * timelines, and `totalProgression` carried whichever one wrote last — so each
 * side read the other's number on its own scale.
 *
 * From the car: tapping *The Hero of Ages* in CarPlay resumed from
 * `atProgress=0.7383`, which was a fraction of the **text**, multiplied by the
 * duration of the **audio**. The book is 109 spine items and 85 narrated ones,
 * so the two are not the same fraction, and 27h25m of audiobook started tens
 * of minutes early.
 */
class AudioAnchorTest {
    companion object {
        /** Four tracks, an hour each, in the shape a Storyteller manifest arrives in. */
        fun manifest(): AudiobookManifest = AudiobookManifest(
            metadata = AudiobookManifest.Metadata(title = mapOf("und" to "The Hero of Ages")),
            readingOrder = listOf(
                AudiobookManifest.Track(href = "chapter01.mp3", duration = 3600.0),
                AudiobookManifest.Track(href = "chapter02.mp3", duration = 3600.0),
                AudiobookManifest.Track(href = "chapter03.mp3", duration = 3600.0),
                AudiobookManifest.Track(href = "chapter04.mp3", duration = 3600.0),
            ),
        )
    }

    /** An anchor is the track's start plus the offset into it. */
    @Test
    fun bookTimeSumsPrecedingTracks() {
        val anchor = AudioAnchor(audioHref = "chapter03.mp3", offset = 120.0, writtenAt = 1.0)
        assertEquals(7320.0, manifest().bookTime(anchor)!!, 0.0)
    }

    /**
     * The EPUB's archive path and the server's href are the same file.
     *
     * The media overlay names an archive path inside the EPUB; the manifest
     * names what the server serves. Same file, two names — and matching on the
     * last *two* components, which is right for text resources, fails here.
     */
    @Test
    fun matchesAcrossDifferentPaths() {
        val anchor = AudioAnchor(audioHref = "OEBPS/audio/Chapter03.MP3", offset = 30.0, writtenAt = 1.0)
        assertEquals(7230.0, manifest().bookTime(anchor)!!, 0.0)
    }

    /** A file no track answers to resolves to nothing: `null`, not a guess. A wrong number here is the whole bug. */
    @Test
    fun unmatchedFileIsRefused() {
        val anchor = AudioAnchor(audioHref = "interview-with-the-author.mp3", offset = 5.0, writtenAt = 1.0)
        assertNull(manifest().bookTime(anchor))
    }

    /**
     * A file name two tracks answer to names neither of them.
     *
     * A book laid out a folder per chapter — `Audio/ch01/track.mp3`,
     * `Audio/ch02/track.mp3` — has one file name for the whole novel. The
     * exact-href pass covers that while every chunk is present; the moment
     * `ChunkManifest.make` drops one for having no file or no length, the
     * anchor naming the dropped chunk falls through to the name pass, and the
     * surviving chapters all still answer to `track.mp3`. Taking the first of
     * them handed back a different chapter *and called it success*, which is
     * what releases the hold on the audio clock. A name several tracks answer
     * to is a name for none of them.
     */
    @Test
    fun anAmbiguousFileNameMatchesNothing() {
        val manifest = AudiobookManifest(
            metadata = AudiobookManifest.Metadata(title = mapOf("und" to "A Novel")),
            readingOrder = listOf(
                AudiobookManifest.Track(href = "OEBPS/Audio/ch01/track.mp3", duration = 120.0),
                AudiobookManifest.Track(href = "OEBPS/Audio/ch03/track.mp3", duration = 90.0),
            ),
        )
        // ch02 was dropped, so nothing matches this href exactly.
        val anchor = AudioAnchor(audioHref = "OEBPS/Audio/ch02/track.mp3", offset = 30.0, writtenAt = 1.0)
        assertNull(manifest.trackIndex(anchor.audioHref))
        assertNull(
            "thirty seconds into a chapter that is not there is not a place in this book",
            manifest.bookTime(anchor),
        )
    }

    /**
     * An exact href still wins over a name two tracks share.
     *
     * The other direction, so the fix cannot be "stop matching on names at
     * all": an anchor that names a track outright is answered by that track,
     * however many of its neighbours share its file name.
     */
    @Test
    fun anExactHrefWinsOverASharedName() {
        val manifest = AudiobookManifest(
            metadata = AudiobookManifest.Metadata(title = mapOf("und" to "A Novel")),
            readingOrder = listOf(
                AudiobookManifest.Track(href = "OEBPS/Audio/ch01/track.mp3", duration = 120.0),
                AudiobookManifest.Track(href = "OEBPS/Audio/ch02/track.mp3", duration = 90.0),
            ),
        )
        val anchor = AudioAnchor(audioHref = "OEBPS/Audio/ch02/track.mp3", offset = 30.0, writtenAt = 1.0)
        assertEquals(1, manifest.trackIndex(anchor.audioHref))
        assertEquals("the first chunk's length, plus the offset into the second", 150.0, manifest.bookTime(anchor)!!, 0.0)
    }

    /**
     * An offset past the end of its track is clamped to that track. An anchor
     * written against a differently transcoded copy can overshoot, and
     * overshooting rolls silently into the next chapter.
     */
    @Test
    fun offsetClampedToTrack() {
        val anchor = AudioAnchor(audioHref = "chapter02.mp3", offset = 9_999.0, writtenAt = 1.0)
        assertEquals(7200.0, manifest().bookTime(anchor)!!, 0.0)
    }

    /** A nonsense offset never becomes a place in the book. */
    @Test
    fun nonFiniteOffsetRefused() {
        assertEquals(0.0, AudioAnchor(audioHref = "a.mp3", offset = Double.NaN, writtenAt = 1.0).offset, 0.0)
        assertEquals(0.0, AudioAnchor(audioHref = "a.mp3", offset = -30.0, writtenAt = 1.0).offset, 0.0)
    }

    /**
     * The anchor lands where scaling a text fraction does not — the
     * regression, stated as arithmetic.
     *
     * A book whose front matter carries text but no audio: the reader is
     * three-quarters through the *text*, which is further than three-quarters
     * through the *audio*, because the unnarrated pages spent text and no
     * seconds. Scaling the text fraction by the audio duration therefore lands
     * early — here by nearly half an hour on a four-hour book, and by tens of
     * minutes on the real 27-hour one.
     */
    @Test
    fun anchorBeatsScalingATextFraction() {
        val manifest = manifest()
        // Where the listener actually is: 10 minutes into the last track.
        val anchor = AudioAnchor(audioHref = "chapter04.mp3", offset = 600.0, writtenAt = 1.0)
        val truth = manifest.bookTime(anchor)!!
        assertEquals(3 * 3600.0 + 600, truth, 0.0)

        // What the old code did with a *text* progression of 0.7383.
        val scaled = manifest.totalDuration * 0.7383

        // Early, and by a margin a listener notices. This synthetic book runs
        // four hours and the gap is already ~12 minutes; *The Hero of Ages*
        // runs 27h25m, where the same fraction error is worth well over an
        // hour. The point is not the size — it is that the two numbers are
        // answers to different questions and only coincidence makes them agree.
        assertTrue("scaling a text fraction lands early, every time", scaled < truth)
        assertTrue("by ${((truth - scaled) / 60).toInt()} minutes here", truth - scaled > 10 * 60)
    }

    /**
     * An anchor written after a position beats it, and one written before
     * does not.
     *
     * The question the resume ladder asks, which is not "is this anchor newer
     * than that one" — that rule ships in SQL, in `setAudioAnchor`, and a
     * Kotlin twin of it would be free to drift. It is "was this anchor written
     * after the reading position that is stored now", because reading on in
     * silence moves the position and leaves the anchor exactly where the
     * narration stopped.
     */
    @Test
    fun anAnchorIsNewerThanAnInstantOrItIsNot() {
        val anchor = AudioAnchor(audioHref = "chapter04.mp3", offset = 10.0, writtenAt = 200.0)
        assertTrue(anchor.isNewerThan(instantOfEpochSeconds(100.0)))
        assertFalse(anchor.isNewerThan(instantOfEpochSeconds(300.0)))
        assertTrue("anything beats a book with no position stored", anchor.isNewerThan(null))
        // Nothing rides on the tie: both writers stamp the anchor *after* the
        // position it belongs to, so an equal instant means the anchor lost a
        // race it was never in.
        assertFalse(anchor.isNewerThan(instantOfEpochSeconds(200.0)))
    }

    // Which clock a stored position is on

    /**
     * A locator says which clock its progression belongs to. Both writers have
     * always recorded the type correctly. Nothing read it, which is why each
     * side interpreted the other's number on its own scale.
     */
    @Test
    fun locatorCarriesItsScale() {
        val fromTheReader = ReadiumLocator(href = "chapter62.xhtml", type = "application/xhtml+xml")
        val fromTheAudiobook = ReadiumLocator(href = "chapter62.mp3", type = "audio/mpeg")
        assertFalse(fromTheReader.isAudioScaled)
        assertTrue(fromTheAudiobook.isAudioScaled)
        // Servers are not reliably lower-case about media types.
        assertTrue(ReadiumLocator(href = "x.m4a", type = "AUDIO/MP4").isAudioScaled)
    }

    // Persistence

    /** An anchor survives a restart, and the newer of two wins. */
    @Test
    fun anchorRoundTrips() = runBlocking {
        withTemporaryDirectory("anchors") { directory ->
            LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
                assertNull(store.audioAnchor(bookUuid = "b1"))

                val first = AudioAnchor(audioHref = "chapter01.mp3", offset = 30.0, writtenAt = 100.0)
                store.setAudioAnchor(first, bookUuid = "b1")
                assertEquals(first, store.audioAnchor(bookUuid = "b1"))

                // The reader and the audiobook both write these, and the phone
                // may have been running while the car was not: last *in time*,
                // not last to arrive.
                val stale = AudioAnchor(audioHref = "chapter01.mp3", offset = 5.0, writtenAt = 50.0)
                store.setAudioAnchor(stale, bookUuid = "b1")
                assertEquals("a stale anchor is refused", first, store.audioAnchor(bookUuid = "b1"))

                val fresh = AudioAnchor(audioHref = "chapter04.mp3", offset = 600.0, writtenAt = 200.0)
                store.setAudioAnchor(fresh, bookUuid = "b1")
                assertEquals(fresh, store.audioAnchor(bookUuid = "b1"))

                // And it is per book.
                assertNull(store.audioAnchor(bookUuid = "b2"))

                LibraryStore(serverKey = "http://example.test", directory = directory).use { reopened ->
                    assertEquals(fresh, reopened.audioAnchor(bookUuid = "b1"))
                }
            }
        }
    }
}
