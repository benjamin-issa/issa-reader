package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.IssaJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * A manifest built in code has to be the same manifest the server's JSON
 * decodes into. Ported from `AudiobookManifestInitTests.swift`.
 *
 * The read-along path synthesises one over the EPUB's narration chunks, so for
 * the first time this type is constructed as well as decoded. Two shapes of
 * the same model is how a field acquires a second meaning — a `type` the
 * decoder fills and the builder forgets, say — and every consumer downstream
 * reads it through one code path that cannot tell which built it. Round
 * tripping through the serializer states that they are one type: whatever the
 * builder puts in survives the encoder, the decoder and `==`.
 */
class AudiobookManifestInitTest {
    /** A manifest built in code equals its decoded twin. */
    @Test
    fun aManifestBuiltInCodeEqualsItsDecodedTwin() {
        val built = AudiobookManifest(
            metadata = AudiobookManifest.Metadata(
                title = mapOf("und" to "The Patient Record of the Days"),
                subtitle = mapOf("und" to "A Fixture"),
                language = listOf("en"),
                duration = 32.75,
            ),
            readingOrder = listOf(
                AudiobookManifest.Track(href = "OEBPS/Audio/track1.mp3", type = "audio/mpeg", duration = 23.0),
                AudiobookManifest.Track(
                    href = "OEBPS/Audio/track2.mp3", type = "audio/mpeg", title = "Chapter Two",
                    duration = 9.75, size = 2_052, bitrate = 128_000.0, rel = listOf("contents"),
                ),
            ),
            links = listOf(AudiobookManifest.Link(href = "manifest.json", type = "application/json", rel = listOf("self"))),
            toc = listOf(AudiobookManifest.Track(href = "OEBPS/Audio/track1.mp3", title = "Chapter One")),
        )

        val data = IssaJson.encodeToString(AudiobookManifest.serializer(), built)
        val decoded = IssaJson.decodeFromString(AudiobookManifest.serializer(), data)

        assertEquals(built, decoded)
        // And the fields the rest of the app actually reads off it, since
        // equality would also hold if both sides were empty.
        assertEquals(32.75, decoded.totalDuration, 0.0)
        assertEquals(2, decoded.playableTracks.size)
        assertEquals("audio/mpeg", decoded.playableTracks[1].type)
        assertEquals("Track 1", decoded.title(of = decoded.playableTracks[0], at = 0))
    }
}

/**
 * `startTime` and `locate(bookTime)` are one function read in two directions,
 * and they have to agree exactly. Ported from `AudiobookManifestInitTests.swift`
 * (`AudiobookManifestLocateTests`).
 *
 * Not approximately: every chapter of a book playing the server's own manifest
 * starts at a number `startTime` produced, and `previousChapter()` hands that
 * number straight back to `locate` to restart it. A boundary that resolves a
 * ULP low is not "a few milliseconds out" — it is the *previous* track, loaded
 * a fraction of a second from its end. It runs out immediately, the coordinator
 * reads that as a chapter ending, and an end-of-chapter sleep timer stops the
 * book. `bookTime(anchor)` adds the same durations up the same way, so a
 * resume from a stored anchor lands a whole chunk early for the same reason.
 */
class AudiobookManifestLocateTest {
    /**
     * Durations only, since nothing else here is read. Built rather than
     * decoded for the reason the suite above exists: it is the same type.
     */
    private fun manifest(durations: List<Double>): AudiobookManifest = AudiobookManifest(
        metadata = AudiobookManifest.Metadata(title = mapOf("und" to "A Book Of Awkward Thirds")),
        readingOrder = durations.mapIndexed { index, duration ->
            AudiobookManifest.Track(href = "t$index.mp3", type = "audio/mpeg", duration = duration)
        },
    )

    /**
     * Locate lands on the track startTime names, for durations that are not
     * whole seconds.
     *
     * The measured case, and the one that shipped. Four tracks of a hundred
     * point one: a left fold of the first three is `300.29999999999995`, and the
     * old subtract-as-you-go walk had already taken a hair *more* than that off
     * its remainder by the time it reached the boundary, so the residual sat
     * just under track two's duration and the answer was the end of track two.
     */
    @Test
    fun locateInvertsStartTimeForFractionalDurations() {
        val subject = manifest(listOf(100.1, 100.1, 100.1, 100.1))

        // The hazard first, so a later change to the arithmetic that made this
        // exact rather than merely equal would be visible here rather than
        // silently making the rest of the test vacuous.
        assertEquals("the sum is not 300.3, and that is the whole problem", 300.29999999999995, subject.startTime(3), 0.0)

        for (index in 0 until 4) {
            val start = subject.startTime(index)
            val located = subject.locate(start)
            assertEquals("startTime($index) == $start located track ${located?.index ?: -1}", index, located?.index)
            assertEquals(
                "and at its start, not ${located?.offset ?: -1} into the one before it",
                0.0, located?.offset ?: -1.0, 0.0,
            )
        }
    }

    /**
     * Whole seconds round-trip either way, which is why this went unnoticed.
     *
     * The twin that was always green, spelled out so nobody re-derives the
     * wrong conclusion from it. Every fixture in the suites that exercise this
     * — `BookClockTests` at 1,000 and 1,600 seconds a track, `ChapterClockTests`
     * at 100 — uses whole seconds, which are exact in binary and sum the same
     * way whichever direction they are added, so the defect could not appear in
     * any of them. Real durations come off an audio file and are never round.
     */
    @Test
    fun wholeSecondsRoundTripRegardless() {
        val subject = manifest(listOf(100.0, 100.0, 100.0, 100.0))

        assertEquals("exact in binary, so exact in both folds", 300.0, subject.startTime(3), 0.0)

        for (index in 0 until 4) {
            val located = subject.locate(subject.startTime(index))
            assertEquals(index, located?.index)
            assertEquals(0.0, located?.offset ?: -1.0, 0.0)
        }
    }

    /**
     * One fractional track is enough to move the boundaries after it, because
     * a book is not one duration repeated: it is whatever the encoder made of
     * forty chapters. One inexact track is enough to move every boundary after
     * it off a representable number.
     */
    @Test
    fun oneFractionalTrackMovesTheBoundariesAfterIt() {
        val subject = manifest(listOf(100.0, 100.2, 100.0))

        assertEquals(200.2, subject.startTime(2), 0.0)

        for (index in 0 until 3) {
            val located = subject.locate(subject.startTime(index))
            assertEquals(index, located?.index)
            assertEquals(0.0, located?.offset ?: -1.0, 0.0)
        }
    }

    /**
     * The places that are not boundaries still resolve as they always did.
     *
     * Everything the old walk already got right, so the rewrite cannot have
     * bought the boundaries at the cost of the ordinary case: a time inside a
     * track, a time before the book, a time past its end — which clamps into
     * the last track rather than refusing, because the clock can run a beat
     * past a stated duration — and a book with nothing playable in it.
     */
    @Test
    fun ordinaryPositionsAreUnchanged() {
        val subject = manifest(listOf(100.1, 100.1, 100.1, 100.1))

        val inside = subject.locate(150.0)
        assertEquals(1, inside?.index)
        assertTrue(abs((inside?.offset ?: 0.0) - 49.9) < 0.001)

        val before = subject.locate(-30.0)
        assertEquals(0, before?.index)
        assertEquals("a negative clock is the start of the book, not a refusal", 0.0, before?.offset ?: -1.0, 0.0)

        val past = subject.locate(100_000.0)
        assertEquals("clamped into the last track", 3, past?.index)
        assertEquals("at its very end", 100.1, past?.offset ?: -1.0, 0.0)

        assertNull("no track to name", manifest(emptyList()).locate(0.0))
    }

    /**
     * Both halves index the playable tracks, not the reading order.
     *
     * The m4b alternate link the server advertises for a single-file audiobook
     * has no duration and always 404s, so `playableTracks` drops it — and both
     * halves of this round trip index into *that* list, not into the reading
     * order. Pinned here because the two are easy to confuse and a mismatch
     * between them would move every boundary by a whole track.
     */
    @Test
    fun bothHalvesIndexThePlayableTracks() {
        val subject = AudiobookManifest(
            metadata = AudiobookManifest.Metadata(title = mapOf("und" to "A Book With A Dead Link")),
            readingOrder = listOf(
                AudiobookManifest.Track(href = "whole.m4b", type = "audio/mp4"),
                AudiobookManifest.Track(href = "t0.mp3", type = "audio/mpeg", duration = 100.1),
                AudiobookManifest.Track(href = "t1.mp3", type = "audio/mpeg", duration = 100.1),
            ),
        )

        assertEquals(2, subject.playableTracks.size)
        val located = subject.locate(subject.startTime(1))
        assertEquals(1, located?.index)
        assertEquals(0.0, located?.offset ?: -1.0, 0.0)
        assertEquals("t1.mp3", subject.playableTracks[located?.index ?: 0].href)
    }
}
