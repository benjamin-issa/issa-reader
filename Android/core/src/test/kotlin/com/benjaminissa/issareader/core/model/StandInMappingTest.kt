package com.benjaminissa.issareader.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** The stand-in's one mapping from seconds in the downloaded file to a track and offset in the server's manifest. */
class StandInMappingTest {
    private fun manifest(vararg durations: Double) = AudiobookManifest(
        AudiobookManifest.Metadata(),
        durations.mapIndexed { i, d -> AudiobookManifest.Track(href = "t$i.mp3", type = "audio/mpeg", duration = d) },
    )

    @Test
    fun aSecondInsideATrackIsThatTracksOffset() {
        val place = StandInMapping.locate(manifest(100.0, 200.0, 300.0), 150.0, 600.0)!!
        assertEquals(1, place.trackIndex)
        assertEquals("t1.mp3", place.track.href)
        assertEquals(50.0, place.offset, 1e-9)
        assertEquals(0.25, place.totalProgression, 1e-9)
    }

    /** The boundary belongs to the track it starts. */
    @Test
    fun aBoundaryIsTheStartOfTheNextTrack() {
        val place = StandInMapping.locate(manifest(100.0, 200.0, 300.0), 300.0, 600.0)!!
        assertEquals(2, place.trackIndex)
        assertEquals(0.0, place.offset, 1e-9)
    }

    @Test
    fun theEndOfTheFileIsTheEndOfTheLastTrack() {
        val place = StandInMapping.locate(manifest(100.0, 200.0, 300.0), 600.0, 600.0)!!
        assertEquals(2, place.trackIndex)
        assertEquals(300.0, place.offset, 1e-9)
        assertEquals(1.0, place.totalProgression, 1e-9)
    }

    @Test
    fun oneTrackIsTheIdentity() {
        val place = StandInMapping.locate(manifest(90.0), 42.0, 90.0)!!
        assertEquals(0, place.trackIndex)
        assertEquals(42.0, place.offset, 1e-9)
        assertEquals(42.0 / 90.0, place.totalProgression, 1e-9)
    }

    /** Within max(2 s, 0.5%): a short book may be two seconds out, a long one half a percent. */
    @Test
    fun aMismatchOfLengthIsNoMapping() {
        assertNull(StandInMapping.locate(manifest(100.0, 200.0), 10.0, 303.1))
        assertNotNull(StandInMapping.locate(manifest(100.0, 200.0), 10.0, 301.9))
        assertNull("0.5% of 36000 s is 180 s", StandInMapping.locate(manifest(18_000.0, 18_000.0), 10.0, 36_181.0))
        assertNotNull(StandInMapping.locate(manifest(18_000.0, 18_000.0), 10.0, 36_179.0))
    }

    @Test
    fun noKeptManifestOrANonFiniteNumberIsNoMapping() {
        assertNull(StandInMapping.locate(null, 10.0, 100.0))
        assertNull(StandInMapping.locate(manifest(100.0), Double.NaN, 100.0))
        assertNull(StandInMapping.locate(manifest(100.0), 10.0, 0.0))
    }
}
