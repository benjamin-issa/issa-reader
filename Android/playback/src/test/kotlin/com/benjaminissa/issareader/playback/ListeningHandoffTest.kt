package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilTimeline
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from `ListeningHandoffTests.swift`.

/**
 * When the car gives the book back to the phone.
 *
 * The two engines are exclusive, so this decision is the only thing standing
 * between "the reader catches up with the voice" and "the book comes off the
 * dashboard at 70mph". Every rung is stated here because staging the real
 * thing needs a car, a car session and a downloaded novel — which is exactly
 * why the ladder was lifted out of the app model in the first place.
 */
class ListeningHandoffTest {
    private val bookUuid = "readalong-uuid"

    private fun anchor(href: String = "OEBPS/Audio/track2.mp3", offset: Double = 1.0): AudioAnchor =
        AudioAnchor(href, offset, 1.0)

    /**
     * Every input already set to the shape that hands the book over, so each
     * test below moves exactly one of them and the reason it gets back is the
     * rung it moved — not some later one it happened to trip on the way.
     */
    private fun decide(
        epubPackage: EpubPackage?,
        timeline: SmilTimeline?,
        listeningBookUuid: String? = bookUuid,
        visibleBookUuid: String? = bookUuid,
        surface: ControlSurface = ControlSurface.PHONE,
        isForeground: Boolean = true,
        resumeWasUnresolved: Boolean = false,
        anchor: AudioAnchor? = anchor(),
        isPlaying: Boolean = true,
        hasReadalong: Boolean = true,
    ): ListeningHandoff.Decision = ListeningHandoff.decide(
        listeningBookUuid = listeningBookUuid,
        visibleBookUuid = visibleBookUuid,
        surface = surface,
        isForeground = isForeground,
        resumeWasUnresolved = resumeWasUnresolved,
        anchor = anchor,
        isPlaying = isPlaying,
        epubPackage = epubPackage,
        timeline = timeline,
        hasReadalong = hasReadalong,
    )

    private fun skipped(skip: ListeningHandoff.Skip) = ListeningHandoff.Decision.Skipped(skip)

    /** The target, or null for a skip. */
    private val ListeningHandoff.Decision.target: ListeningHandoff.Target?
        get() = (this as? ListeningHandoff.Decision.HandOff)?.target

    // Placing an anchor

    /**
     * The bridge, in the direction that matters here: the car knows a file and
     * an offset, and only the overlay can say which sentence of which chapter
     * that is.
     */
    @Test
    fun anAnchorPlacesOnItsSentence() {
        val (timeline, epubPackage) = readalongTimeline()

        val placed = checkNotNull(ListeningHandoff.place(anchor(), epubPackage, timeline))

        assertEquals("track two narrates the second chapter", 1, placed.spineIndex)
        assertEquals("ch02-s0", placed.entry.fragmentId)
        assertEquals("OEBPS/ch02.xhtml", placed.entry.textHref)
    }

    /**
     * A chunk whose first clip starts a beat in, and an anchor from before it.
     * No sentence is being spoken there, so the exact lookup answers nothing —
     * but the file still names the chapter, and landing nowhere would leave a
     * listener who parked in the pause between sentences with a page that never
     * turned.
     */
    @Test
    fun anOffsetBeforeTheFirstClipFallsBackToTheFile() {
        val (_, epubPackage) = readalongTimeline()
        // Hand-built rather than parsed: the fixture's overlays both start at
        // zero, and the whole case is a first clip that does not.
        val timeline = SmilTimeline(
            listOf(
                SmilEntry("ch01-s0", "OEBPS/ch01.xhtml", "OEBPS/Audio/track1.mp3", 0.0, 4.0, 4.0),
                SmilEntry("ch02-s0", "OEBPS/ch02.xhtml", "OEBPS/Audio/track2.mp3", 0.5, 5.0, 8.5),
            ),
        )

        val placed = checkNotNull(ListeningHandoff.place(anchor("OEBPS/Audio/track2.mp3", 0.1), epubPackage, timeline))

        assertEquals("ch02-s0", placed.entry.fragmentId)
        assertEquals(1, placed.spineIndex)
    }

    /**
     * The server's single upload against the EPUB's own chunks — the mismatch
     * `ListeningResume` guards from the other side. Refusing is the point: a
     * guess here is a page turn to somewhere the listener has never been.
     */
    @Test
    fun anUnknownFilePlacesNowhere() {
        val (timeline, epubPackage) = readalongTimeline()
        assertNull(ListeningHandoff.place(anchor("The Outsider.mp3", 900.0), epubPackage, timeline))
    }

    // The ladder, rung by rung

    /** Nothing playing is nothing to hand over. */
    @Test
    fun notListening() {
        val (timeline, epubPackage) = readalongTimeline()
        assertEquals(
            skipped(ListeningHandoff.Skip.NOT_LISTENING),
            decide(epubPackage, timeline, listeningBookUuid = null),
        )
    }

    /** No reader on screen is nobody to hand it to. */
    @Test
    fun noVisibleReader() {
        val (timeline, epubPackage) = readalongTimeline()
        assertEquals(skipped(ListeningHandoff.Skip.NO_VISIBLE_READER), decide(epubPackage, timeline, visibleBookUuid = null))
    }

    /**
     * Browsing another book while the audiobook runs. Handing over here would
     * stop the audio for a book nobody asked about.
     */
    @Test
    fun differentBook() {
        val (timeline, epubPackage) = readalongTimeline()
        assertEquals(
            skipped(ListeningHandoff.Skip.DIFFERENT_BOOK),
            decide(epubPackage, timeline, visibleBookUuid = "some-other-book"),
        )
    }

    /**
     * The rung that exists for a person rather than for the code. A phone in a
     * pocket reports a visible reader and a foreground app for the whole drive.
     */
    @Test
    fun carConnected() {
        val (timeline, epubPackage) = readalongTimeline()
        assertEquals(skipped(ListeningHandoff.Skip.CAR_CONNECTED), decide(epubPackage, timeline, surface = ControlSurface.CAR))
    }

    /**
     * Being backgrounded does not dismiss the reader, so a visible reader alone
     * would fire this from a pocket.
     */
    @Test
    fun background() {
        val (timeline, epubPackage) = readalongTimeline()
        assertEquals(skipped(ListeningHandoff.Skip.BACKGROUND), decide(epubPackage, timeline, isForeground = false))
    }

    /**
     * The same rung on a device with no car in it: the phone surface for the
     * life of the process, so `background` is the only thing between a
     * `readerReady` trigger and a book taken off the audiobook engine while the
     * app sits behind another one.
     */
    @Test
    fun backgroundHoldsWithNoCarInSight() {
        val (timeline, epubPackage) = readalongTimeline()
        assertEquals(
            skipped(ListeningHandoff.Skip.BACKGROUND),
            decide(epubPackage, timeline, surface = ControlSurface.PHONE, isForeground = false),
        )
    }

    /**
     * The hole the anchor alone cannot see.
     *
     * A listener upgrading has a stored position on the *audio* clock naming the
     * server's original upload. Against a manifest synthesised over the EPUB's
     * own chunks every rung of `ListeningResume` misses, so the audio clock is
     * held and the book plays from zero. Chunk one at offset zero is a perfectly
     * placeable anchor: it resolves to the overlay's first sentence, the reader
     * turns to page one, and the save that follows is on the *text* clock, whose
     * guard nobody armed and whose seed is zero because the stored locator is on
     * the other one. That is the whole loss, reached the other way round.
     */
    @Test
    fun resumeUnresolved() {
        val (timeline, epubPackage) = readalongTimeline()
        assertEquals(
            skipped(ListeningHandoff.Skip.RESUME_UNRESOLVED),
            decide(epubPackage, timeline, resumeWasUnresolved = true),
        )
    }

    /**
     * Where it sits, which is the whole reason the rungs are ordered: below the
     * two that exist for a person, and above `readerNotReady`, because it is a
     * fact about the book rather than about the reader.
     */
    @Test
    fun resumeUnresolvedSitsBelowThePersonAndAboveTheReader() {
        val (timeline, epubPackage) = readalongTimeline()

        assertEquals(
            skipped(ListeningHandoff.Skip.CAR_CONNECTED),
            decide(epubPackage, timeline, surface = ControlSurface.CAR, resumeWasUnresolved = true),
        )
        assertEquals(
            skipped(ListeningHandoff.Skip.BACKGROUND),
            decide(epubPackage, timeline, isForeground = false, resumeWasUnresolved = true),
        )
        assertEquals(
            "a reader still opening changes nothing about a clock nobody resolved",
            skipped(ListeningHandoff.Skip.RESUME_UNRESOLVED),
            decide(null, timeline, resumeWasUnresolved = true),
        )
    }

    /**
     * Three ways to be half-open, and all of them mean the same thing: there is
     * nothing yet to aim at. `readerReady` brings the decision back.
     */
    @Test
    fun readerNotReady() {
        val (timeline, epubPackage) = readalongTimeline()
        assertEquals(skipped(ListeningHandoff.Skip.READER_NOT_READY), decide(null, timeline))
        assertEquals(skipped(ListeningHandoff.Skip.READER_NOT_READY), decide(epubPackage, null))
        assertEquals(skipped(ListeningHandoff.Skip.READER_NOT_READY), decide(epubPackage, timeline, hasReadalong = false))
    }

    /**
     * An engine that has played nothing has no place to hand over — the same
     * refusal `ReadalongCoordinator.currentAnchor` makes for the same reason.
     */
    @Test
    fun noAnchor() {
        val (timeline, epubPackage) = readalongTimeline()
        assertEquals(skipped(ListeningHandoff.Skip.NO_ANCHOR), decide(epubPackage, timeline, anchor = null))
    }

    /** An anchor the overlay cannot place hands nothing over. */
    @Test
    fun anchorNamesNoFile() {
        val (timeline, epubPackage) = readalongTimeline()
        assertEquals(
            skipped(ListeningHandoff.Skip.ANCHOR_NAMES_NO_FILE),
            decide(epubPackage, timeline, anchor = anchor("The Outsider.mp3", 900.0)),
        )
    }

    // Handing over

    /** A car still playing hands over a sentence to carry on from. */
    @Test
    fun handsOverWhilePlaying() {
        val (timeline, epubPackage) = readalongTimeline()

        val target = checkNotNull(decide(epubPackage, timeline, isPlaying = true).target)

        assertTrue("the phone has to carry the voice on", target.wasPlaying)
        assertEquals(1, target.spineIndex)
        assertEquals("ch02-s0", target.entry.fragmentId)
        assertEquals(anchor(), target.anchor)
    }

    /** The driver pressed pause at the door. The page still has to move; the room stays quiet. */
    @Test
    fun handsOverWhilePaused() {
        val (timeline, epubPackage) = readalongTimeline()

        val target = checkNotNull(decide(epubPackage, timeline, isPlaying = false).target)

        assertFalse(target.wasPlaying)
        assertEquals(1, target.spineIndex)
    }

    /**
     * The anchor a real audiobook engine actually produces, rather than one
     * written by hand: a coordinator over the fixture's own chunks, seeked past
     * the end of the first track. If the two ever disagree about how a track is
     * named, this is what says so.
     */
    @Test
    fun aLiveCoordinatorsAnchorPlaces() = runTest {
        val (timeline, epubPackage) = readalongTimeline()
        val directory = scratchDirectory("issa-handoff")
        try {
            val files = AudioExtraction.extractAudio(epubPackage, timeline, "handoff", directory)
            val built = ChunkManifest.make(timeline, epubPackage, files, emptyMap(), "Fixture")
            val subject = AudiobookCoordinator(
                built.manifest, AudiobookCoordinator.Source.Files(built.files), player = scriptedPlayer(),
                scope = backgroundScope,
            )
            subject.player.onTimeUpdate = null

            val first = checkNotNull(built.manifest.playableTracks.first().duration)
            subject.seekToBookTime(first + 1)

            val anchor = checkNotNull(subject.currentAnchor)
            val placed = checkNotNull(ListeningHandoff.place(anchor, epubPackage, timeline))
            assertEquals("one second into track two is the second chapter", 1, placed.spineIndex)
        } finally {
            directory.deleteRecursively()
        }
    }
}
