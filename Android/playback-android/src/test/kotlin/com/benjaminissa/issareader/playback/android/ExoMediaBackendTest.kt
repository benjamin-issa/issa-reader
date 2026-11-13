package com.benjaminissa.issareader.playback.android

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import androidx.media3.common.PlaybackParameters
import androidx.media3.test.utils.FakeClock
import com.benjaminissa.issareader.playback.AudioLocation
import com.benjaminissa.issareader.playback.AudioPlayer
import kotlinx.coroutines.async
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import java.io.File
import java.nio.file.Files
import kotlin.math.abs

// The player over the real engine, where the Swift suites exercised
// AVFoundation: what a file that opens, one that will not, an exact seek, a
// race between a load and a seek, the end of a file, the speed and the gain do
// on ExoPlayer itself. Ported in spirit from `AudioPlayerEpochTests`,
// `DeadItemTests` and `AudioPlayerGainTests`.

@RunWith(RobolectricTestRunner::class)
class ExoMediaBackendTest {
    private lateinit var context: Context
    private lateinit var directory: File
    private val clock = FakeClock(/* isAutoAdvancing = */ true)
    private val made = ArrayList<AudioPlayer>()

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        directory = Files.createTempDirectory("issa-exo").toFile()
    }

    @After
    fun tearDown() {
        made.forEach { it.release() }
        directory.deleteRecursively()
    }

    private fun backend(): ExoMediaBackend = ExoMediaBackend(context, OkHttpClient(), clock = clock)

    private fun player(backend: ExoMediaBackend = backend()): AudioPlayer = AudioPlayer(backend).also { made.add(it) }

    private val ExoMediaBackend.engineTime: Double get() = exoPlayer.currentPosition / 1000.0

    private fun silence(seconds: Double = 30.0): AudioLocation =
        AudioLocation.LocalFile(wav(File(directory, "silence-$seconds.wav"), seconds))

    /** A file that opens is loaded, with the length the engine reads off it. */
    @Test
    fun aFileLoadsWithItsLength() {
        val player = player()
        val outcome = onMain(clock) { player.load(silence(30.0), "silence.wav") }

        assertEquals(AudioPlayer.LoadOutcome.LOADED, outcome)
        assertEquals(30.0, player.duration, 0.01)
        assertEquals("the gain stage carries every item that opens", true, player.tapCarriesGain)
    }

    /**
     * The player was told to play, the next file would not open, and it said
     * nothing: the load reported success and every surface drew a pause glyph
     * over silence.
     */
    @Test
    fun aFileThatWillNotOpenStopsThePlayer() {
        val backend = backend()
        val player = player(backend)
        onMain(clock) { player.play() }

        val outcome = onMain(clock) {
            player.load(AudioLocation.LocalFile(File(directory, "missing.mp3")), "missing.mp3", startAt = 30.0)
        }

        assertEquals(AudioPlayer.LoadOutcome.FAILED, outcome)
        assertFalse(player.isPlaying)
        assertFalse(backend.exoPlayer.playWhenReady)
        assertTrue(player.itemHasFailed)
        // And the next press claims nothing over it.
        onMain(clock) { player.play() }
        assertFalse(player.isPlaying)
    }

    /**
     * A clip time is whatever the overlay says, `1e20s` included; the seek
     * lands at the end of the item rather than overflowing the engine.
     */
    @Test
    fun anAbsurdSeekDoesNotTrap() {
        for (seconds in listOf(1.6e16, 1e20, 1e300, Double.POSITIVE_INFINITY)) {
            val player = player()
            onMain(clock) {
                player.load(silence(5.0), "silence.wav")
                player.seek(seconds)
            }
            assertTrue("$seconds", player.currentTime.isFinite())
        }
    }

    /**
     * Exact: the engine lands where it was sent, rounded up onto the grid and
     * never below — the read-along's highlight depends on it.
     */
    @Test
    fun aLoadLandsExactlyWhereItAsked() {
        val backend = backend()
        val player = player(backend)
        val target = 12.3456
        val outcome = onMain(clock) { player.load(silence(30.0), "silence.wav", startAt = target) }

        assertEquals(AudioPlayer.LoadOutcome.LOADED, outcome)
        assertEquals(target, player.currentTime, 0.0)
        val engine = backend.engineTime
        assertTrue("the engine is at $engine", engine >= target)
        assertTrue("the engine is at $engine", engine - target < 0.003)
    }

    /**
     * A seek into the file a load is still opening owns the playhead, and the
     * load says so rather than running its trailing seek over it. Queued before
     * the load begins, so it runs at the load's own suspension inside the
     * engine — the window a real overtaking command lands in.
     */
    @Test
    fun aSeekDuringALoadOvertakesIt() {
        val backend = backend()
        val player = player(backend)

        val outcome = onMain(clock) {
            val racing = async { player.seek(7.0) }
            val outcome = player.load(silence(30.0), "silence.wav", startAt = 20.0)
            racing.await()
            outcome
        }

        assertEquals(AudioPlayer.LoadOutcome.OVERTAKEN, outcome)
        assertEquals(7.0, player.currentTime, 0.01)
        assertTrue("the engine ran the load's trailing seek: ${backend.engineTime}", abs(backend.engineTime - 7) < 0.01)
    }

    /** A load another load replaced owns nothing, and writes nothing. */
    @Test
    fun aSupersededLoadWritesNothing() {
        val backend = backend()
        val player = player(backend)

        val (older, newer) = onMain(clock) {
            val racing = async { player.load(silence(20.0), "newer.wav", startAt = 4.0) }
            val older = player.load(silence(30.0), "older.wav", startAt = 25.0)
            older to racing.await()
        }

        assertEquals(AudioPlayer.LoadOutcome.SUPERSEDED, older)
        assertEquals(AudioPlayer.LoadOutcome.LOADED, newer)
        assertEquals("newer.wav", player.currentAudioHref)
        assertEquals(20.0, player.duration, 0.01)
        assertTrue("the superseded load seeked the newer item: ${backend.engineTime}", abs(backend.engineTime - 4) < 0.01)
    }

    /** A file that plays to its end says so, which is what moves a book on. */
    @Test
    fun theEndOfAFileIsReported() {
        val player = player()
        var ended = 0
        player.onFinishedFile = { ended += 1 }

        onMain(clock) {
            player.load(silence(1.0), "silence.wav")
            player.play()
        }
        runUntil(clock) { ended > 0 }

        assertEquals(1, ended)
    }

    /** Speed through Sonic with the pitch held, and only once there is something to play. */
    @Test
    fun theRateKeepsThePitch() {
        val backend = backend()
        val player = player(backend)
        onMain(clock) {
            player.load(silence(10.0), "silence.wav")
            player.rate = 1.5f
        }
        assertFalse("a paused book does not start for a speed", backend.exoPlayer.playWhenReady)

        onMain(clock) { player.play() }
        assertEquals(PlaybackParameters(1.5f, 1f), backend.exoPlayer.playbackParameters)
        assertTrue(backend.exoPlayer.playWhenReady)
    }

    /** The book's level reaches the gain stage, and the fade keeps the engine's own volume. */
    @Test
    fun theGainReachesTheStage() {
        val backend = backend()
        val player = player(backend)
        onMain(clock) { player.load(silence(5.0), "silence.wav") }

        player.gain = 2f
        assertEquals(2f, backend.gainProcessor.gain)
        assertEquals("the gain is in the samples, not the volume", 1f, backend.exoPlayer.volume)
        player.volume = 0.5f
        assertEquals(0.5f, backend.exoPlayer.volume)
    }

    /**
     * Audio focus is the session: taken when narration is asked for, and given
     * back at the ends of listening. A call interrupts and, when it is over, the
     * book carries on for a listener who was listening.
     */
    @Test
    fun focusIsTheSession() {
        val backend = backend()
        val player = player(backend)
        val audioManager = context.getSystemService(AudioManager::class.java)
        val shadow = shadowOf(audioManager)
        val interruptions = ArrayList<Boolean>()
        player.onInterruption = { interruptions.add(it) }

        onMain(clock) { player.load(silence(30.0), "silence.wav") }
        assertEquals("opening a book takes nothing", null, shadow.lastAudioFocusRequest)

        onMain(clock) { player.play() }
        val request = checkNotNull(shadow.lastAudioFocusRequest) { "playing took no focus" }
        assertTrue(backend.exoPlayer.playWhenReady)

        request.listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        runUntil(clock) { interruptions.isNotEmpty() }
        assertFalse(player.isPlaying)
        assertFalse(backend.exoPlayer.playWhenReady)

        request.listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_GAIN)
        runUntil(clock) { interruptions.size == 2 }
        assertEquals(listOf(false, true), interruptions)
        assertTrue(player.isPlaying)
        assertTrue(backend.exoPlayer.playWhenReady)

        onMain(clock) { player.endSession() }
        assertFalse(player.isPlaying)
    }

    /**
     * A refused focus request leaves the player paused: the engine is held
     * silent, and the transport must not say it is playing over that.
     */
    @Test
    fun aRefusedFocusRequestLeavesThePlayerPaused() {
        val backend = backend()
        val player = player(backend)
        val shadow = shadowOf(context.getSystemService(AudioManager::class.java))
        onMain(clock) { player.load(silence(30.0), "silence.wav") }

        shadow.setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
        onMain(clock) { player.play() }
        assertFalse(player.isPlaying)
        assertFalse(backend.exoPlayer.playWhenReady)

        // Asked again, and granted.
        shadow.setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        onMain(clock) { player.play() }
        assertTrue(player.isPlaying)
        assertTrue(backend.exoPlayer.playWhenReady)
    }

    /**
     * Another player took the route for good: the book is paused, the interruption
     * has no end to wait for, and nothing asks for focus again until the listener
     * presses Play.
     */
    @Test
    fun aPermanentFocusLossPausesAndTakesNothingBack() {
        val backend = backend()
        val player = player(backend)
        val shadow = shadowOf(context.getSystemService(AudioManager::class.java))
        onMain(clock) { player.load(silence(30.0), "silence.wav") }
        onMain(clock) { player.play() }
        val request = checkNotNull(shadow.lastAudioFocusRequest)
        val token = onMain(clock) { player.startToken() }

        request.listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS)
        runUntil(clock) { !player.isPlaying }
        assertFalse(backend.exoPlayer.playWhenReady)

        // A start whose load spanned the loss does not take the route back. A
        // refusal is queued: if the start asked, it would use that refusal up.
        shadow.setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
        assertFalse(onMain(clock) { player.playUnlessOvertaken(token) })
        assertFalse(player.isPlaying)

        // The listener's own Play asks, here meets the queued refusal, and asks again.
        onMain(clock) { player.play() }
        assertFalse("the start had already used the refusal", player.isPlaying)
        shadow.setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        onMain(clock) { player.play() }
        assertTrue(player.isPlaying)
        assertTrue(backend.exoPlayer.playWhenReady)
    }

    /** A Play pressed during a transient loss asks for focus again rather than playing over the holder or latching. */
    @Test
    fun aPlayDuringATransientLossAsksForFocusAgain() {
        val backend = backend()
        val player = player(backend)
        val shadow = shadowOf(context.getSystemService(AudioManager::class.java))
        onMain(clock) { player.load(silence(30.0), "silence.wav") }
        onMain(clock) { player.play() }
        val request = checkNotNull(shadow.lastAudioFocusRequest)
        request.listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        runUntil(clock) { !player.isPlaying }

        // Refused: stays paused, and is not latched to start when focus returns.
        shadow.setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
        onMain(clock) { player.play() }
        assertFalse(player.isPlaying)

        // Granted: plays now.
        shadow.setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        onMain(clock) { player.play() }
        assertTrue("the listener's Play during a transient loss was swallowed", player.isPlaying)
        assertTrue(backend.exoPlayer.playWhenReady)
    }

    /**
     * A re-request refused during a transient loss leaves focus not held while the
     * first request is still on the system's stack: ending the session abandons it.
     */
    @Test
    fun endingTheSessionAfterARefusedReRequestAbandonsFocus() {
        val backend = backend()
        val player = player(backend)
        val shadow = shadowOf(context.getSystemService(AudioManager::class.java))
        onMain(clock) { player.load(silence(30.0), "silence.wav") }
        onMain(clock) { player.play() }
        val request = checkNotNull(shadow.lastAudioFocusRequest)
        request.listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        runUntil(clock) { !player.isPlaying }
        shadow.setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
        onMain(clock) { player.play() }
        assertFalse(player.isPlaying)
        assertEquals(null, shadow.lastAbandonedAudioFocusRequest)

        onMain(clock) { player.endSession() }

        assertTrue("the request leaked", shadow.lastAbandonedAudioFocusRequest != null)
    }

    /** Headphones out: the engine pauses, and the player hears of a lost route. */
    @Test
    fun becomingNoisyPauses() {
        val backend = backend()
        val player = player(backend)
        var lost = 0
        player.onRouteLoss = { lost += 1 }
        onMain(clock) {
            player.load(silence(30.0), "silence.wav")
            player.play()
        }
        runUntil(clock) { backend.exoPlayer.isPlaying }

        context.sendBroadcast(Intent(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        runUntil(clock) { lost > 0 }

        assertFalse(player.isPlaying)
        assertFalse(backend.exoPlayer.playWhenReady)
    }

    /** The clock observes at a fifth of a second while a reader follows it, and a second otherwise. */
    @Test
    fun theClockTicks() {
        val player = player()
        val ticks = ArrayList<Double>()
        player.onTimeUpdate = { ticks.add(it) }
        onMain(clock) { player.load(silence(30.0), "silence.wav", startAt = 3.0) }
        ticks.clear()

        player.setHighFrequencyUpdates(true)
        shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(1_000))
        assertTrue("a fifth of a second apart, ${ticks.size} ticks in a second", ticks.size in 4..6)
        assertTrue(ticks.all { it.isFinite() })

        ticks.clear()
        player.setHighFrequencyUpdates(false)
        shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(3_000))
        assertTrue("a second apart, ${ticks.size} ticks in three", ticks.size in 2..4)
    }

    /**
     * The stream's cookie is for the server it was issued by. A redirect to
     * another host (or another scheme, for an https server) must not carry it.
     */
    @Test
    fun theStreamTokenCookieGoesToTheServersHostAlone() {
        val server = AudioLocation.Remote(
            "https://books.example/api/v2/books/uuid/listen/a.mp3",
            mapOf("Authorization" to "Bearer t", "Cookie" to "st_token=secret"),
        )
        val jar = backend().clientFor(server).cookieJar
        fun sent(url: String) = jar.loadForRequest(okhttp3.HttpUrl.Builder().scheme(url.substringBefore("://")).host(url.substringAfter("://").substringBefore("/")).build())
            .map { "${it.name}=${it.value}" }

        assertEquals(listOf("st_token=secret"), sent("https://books.example/x"))
        assertEquals(emptyList<String>(), sent("https://cdn.elsewhere.example/x"))
        assertEquals("a subdomain is another host", emptyList<String>(), sent("https://evil.books.example/x"))
        assertEquals("never in the clear", emptyList<String>(), sent("http://books.example/x"))
    }

    @Test
    fun aStreamWithNoCookieKeepsTheSharedClient() {
        val plain = AudioLocation.Remote("https://books.example/a.mp3", mapOf("Authorization" to "Bearer t"))
        assertEquals(okhttp3.CookieJar.NO_COOKIES, backend().clientFor(plain).cookieJar)
    }
}
