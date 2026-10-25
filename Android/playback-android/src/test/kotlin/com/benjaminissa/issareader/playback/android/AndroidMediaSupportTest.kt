package com.benjaminissa.issareader.playback.android

import androidx.media3.test.utils.robolectric.ShadowMediaCodecConfig
import com.benjaminissa.issareader.epub.EpubInspection
import com.benjaminissa.issareader.playback.AudioPlayability
import com.benjaminissa.issareader.testing.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

// What `LocalNarrationTests.swift` asked AVFoundation, asked of Android's codec
// list. The rules on top of the platform's answer are `:playback`'s
// `LocalNarrationTest`; this is the answer itself, and it differs from the
// iPhone's in one place: Android decodes Opus.

@RunWith(RobolectricTestRunner::class)
class AndroidMediaSupportTest {
    /** The decoders a stock device has, as ExoPlayer's own tests stand them up. */
    @get:Rule
    val codecs: ShadowMediaCodecConfig = ShadowMediaCodecConfig.withAllDefaultSupportedCodecs()

    private val device = AndroidMediaSupport()

    /** IssaPlayback's own fixtures hold the two read-alongs; the generated local-import books live with IssaEPUB's. */
    private fun book(name: String) =
        if (name.startsWith("readalong") && name != "readalong-opus") Fixtures.playback("$name.epub") else Fixtures.epub("$name.epub")

    /** The device's decoders are what is asked, and the formats narration comes in are among them. */
    @Test
    fun theDeviceDecodesWhatNarrationComesIn() {
        val decoders = AndroidMediaSupport.deviceDecoders()
        assertTrue("$decoders", "audio/mpeg" in decoders)
        assertTrue("$decoders", "audio/mp4a-latm" in decoders)

        assertTrue(device.isPlayable("audio/mpeg"))
        assertTrue("an M4A is AAC inside", device.isPlayable("audio/mp4"))
        assertTrue(device.isPlayable("audio/x-m4b"))
        assertTrue("parameters are not part of the type", device.isPlayable("audio/mpeg; codecs=mp3"))
        assertTrue("and neither is case", device.isPlayable("Audio/MPEG"))
    }

    /** Where Android parts from the iPhone: Opus is narrated here. */
    @Test
    fun opusPlaysOnAndroid() {
        assertTrue(device.isPlayable("audio/opus"))
        assertTrue(device.isPlayable("audio/ogg"))
        assertTrue(AudioPlayability.isPlayable("audio/opus", "a.opus", device))
    }

    /** PCM needs no decoder, so a WAVE file plays on a device that lists none. */
    @Test
    fun pcmNeedsNoDecoder() {
        val bare = AndroidMediaSupport { emptySet() }
        assertTrue(bare.isPlayable("audio/wav"))
        assertTrue(bare.isPlayable("audio/x-wav"))
        assertFalse("and nothing else plays without one", bare.isPlayable("audio/mpeg"))
        assertFalse(bare.isPlayable("audio/opus"))
    }

    /** A type no decoder accepts, or that is no audio at all, does not play. */
    @Test
    fun whatNothingDecodesDoesNotPlay() {
        val mp3Only = AndroidMediaSupport { setOf("audio/mpeg") }
        assertTrue(mp3Only.isPlayable("audio/mpeg"))
        assertFalse(mp3Only.isPlayable("audio/mp4"))
        assertFalse(mp3Only.isPlayable("audio/ogg"))
        assertFalse(device.isPlayable("application/xhtml+xml"))
        assertFalse(device.isPlayable("audio/x-made-up"))
    }

    /** No declared type: the extension stands in for one, as `UTType` does on iOS. */
    @Test
    fun theExtensionStandsInForATypeNotDeclared() {
        assertEquals("audio/mpeg", device.mimeType("mp3"))
        assertEquals("audio/mpeg", device.mimeType("MP3"))
        assertEquals("audio/mp4", device.mimeType("m4b"))
        // The platform's map files `.opus` under its Ogg container, which is
        // what it is, and the Ogg decoders include Opus.
        assertTrue(device.mimeType("opus") in setOf("audio/ogg", "audio/opus"))
        assertEquals(null, device.mimeType("xhtml-not-audio"))

        assertTrue(AudioPlayability.isPlayable(null, "OEBPS/Audio/a.mp3", device))
        assertTrue(AudioPlayability.isPlayable("", "OEBPS/Audio/a.m4a", device))
        assertTrue(AudioPlayability.isPlayable(null, "OEBPS/Audio/a.opus", device))
        assertFalse(AudioPlayability.isPlayable(null, "OEBPS/Audio/a", device))
    }

    /** The two read-alongs narrate, and so does the Opus one the iPhone adds as text. */
    @Test
    fun theFixturesNarrate() {
        assertTrue(AudioPlayability.canNarrate(EpubInspection.inspect(book("readalong")), device))
        assertTrue(AudioPlayability.canNarrate(EpubInspection.inspect(book("readalong-v3")), device))
        val opus = EpubInspection.inspect(book("readalong-opus"))
        assertTrue(opus.hasCompleteNarration)
        assertTrue("Android decodes Opus", AudioPlayability.canNarrate(opus, device))
    }

    /** A book with no narration has none to play, whatever the device decodes. */
    @Test
    fun noNarration() {
        assertFalse(AudioPlayability.canNarrate(EpubInspection.inspect(book("epub2-meta-cover")), device))
    }
}
