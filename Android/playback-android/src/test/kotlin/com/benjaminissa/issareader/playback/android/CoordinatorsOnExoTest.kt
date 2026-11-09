package com.benjaminissa.issareader.playback.android

import android.content.Context
import android.media.AudioManager
import androidx.media3.test.utils.FakeClock
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilTimeline
import com.benjaminissa.issareader.playback.AudioLocation
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.AudiobookCoordinator
import com.benjaminissa.issareader.playback.ReadalongCoordinator
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import java.io.File
import java.nio.file.Files
import java.util.Collections

// The coordinators over the real engine, where the Swift suites leaned on
// AVFoundation ending a file: `SessionEndTests`, the end-of-file advances in
// `BookClockTests` and `ReadalongCoordinatorTests`, and a stream fetched with
// the server's credentials.

@RunWith(RobolectricTestRunner::class)
class CoordinatorsOnExoTest {
    private lateinit var context: Context
    private lateinit var directory: File
    private val clock = FakeClock(/* isAutoAdvancing = */ true)
    private val made = ArrayList<AudioPlayer>()

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        directory = Files.createTempDirectory("issa-exo-coordinators").toFile()
    }

    @After
    fun tearDown() {
        made.forEach { it.release() }
        directory.deleteRecursively()
    }

    private fun player(client: OkHttpClient = OkHttpClient()): AudioPlayer =
        AudioPlayer(ExoMediaBackend(context, client, clock = clock)).also { made.add(it) }

    private fun track(name: String, seconds: Double): File = wav(File(directory, name), seconds)

    /**
     * Two one-second tracks played through: the file boundary moves the book on
     * and keeps it playing, and the end of the book stops it and gives the audio
     * route back.
     */
    @Test
    fun anAudiobookPlaysThroughAndEndsItsSession() {
        val manifest = AudiobookManifest(
            metadata = AudiobookManifest.Metadata(title = mapOf("und" to "Two Tracks")),
            readingOrder = listOf(
                AudiobookManifest.Track(href = "track0.wav", type = "audio/wav", duration = 1.0),
                AudiobookManifest.Track(href = "track1.wav", type = "audio/wav", duration = 1.0),
            ),
        )
        val subject = AudiobookCoordinator(
            manifest,
            AudiobookCoordinator.Source.Files(
                mapOf("track0.wav" to track("track0.wav", 1.0), "track1.wav" to track("track1.wav", 1.0)),
            ),
            player = player(),
            scope = mainScope(),
        )
        val chapters = Collections.synchronizedList(ArrayList<Int>())
        var endings = 0
        subject.onChapterChange = { chapters.add(it) }
        subject.onChapterChangeObserved = { endings += 1 }

        assertEquals(AudiobookCoordinator.MoveOutcome.LANDED, onMain(clock) { subject.start(atProgress = 0.0) })
        assertTrue(subject.player.isPlaying)

        runUntil(clock) { subject.trackIndex == 1 && chapters.size >= 2 }
        assertTrue("a track boundary is not the end of the book", subject.player.isPlaying)
        assertEquals(1, endings)

        val audioManager = context.getSystemService(AudioManager::class.java)
        runUntil(clock) { !subject.player.isPlaying }
        assertEquals(1, subject.trackIndex)
        assertNotNull("the end of the book kept the audio route", shadowOf(audioManager).lastAbandonedAudioFocusRequest)
    }

    /**
     * A read-along whose chapter ends with its file: the end of the file moves
     * the narration into the next file and reports the chapter that ran out.
     */
    @Test
    fun aReadalongChapterThatRunsOutReportsAnEnding() {
        val one = "OEBPS/Audio/one.wav"
        val two = "OEBPS/Audio/two.wav"
        val timeline = SmilTimeline(
            listOf(
                SmilEntry("ch01-s0", "OEBPS/ch01.xhtml", one, 0.0, 1.0, 1.0),
                SmilEntry("ch02-s0", "OEBPS/ch02.xhtml", two, 0.0, 1.0, 2.0),
            ),
        )
        val subject = ReadalongCoordinator(
            timeline,
            mapOf(one to track("one.wav", 1.0), two to track("two.wav", 1.0)),
            player(),
            mainScope(),
        )
        var endings = 0
        subject.onChapterChangeObserved = { endings += 1 }

        assertTrue(onMain(clock) { subject.play(timeline.entries[0]) })
        runUntil(clock) { endings > 0 }

        assertEquals(1, endings)
        assertEquals(timeline.entries[1], subject.activeEntry)
        assertEquals(two, subject.player.currentAudioHref)
    }

    /**
     * A streamed track is fetched through the caller's client with the session
     * token both ways the server's audio routes take it, and plays.
     */
    @Test
    fun aStreamCarriesTheServersCredentials() {
        val body = wav(File(directory, "stream.wav"), 3.0).readBytes()
        val requests = Collections.synchronizedList(ArrayList<Request>())
        val client = OkHttpClient.Builder()
            .addInterceptor { chain ->
                requests.add(chain.request())
                Response.Builder()
                    .request(chain.request())
                    .protocol(Protocol.HTTP_1_1)
                    .code(200)
                    .message("OK")
                    .body(body.toResponseBody("audio/wav".toMediaType()))
                    .build()
            }
            .build()
        val manifest = AudiobookManifest(
            metadata = AudiobookManifest.Metadata(title = mapOf("und" to "Streamed")),
            readingOrder = listOf(AudiobookManifest.Track(href = "The Outsider.wav", type = "audio/wav", duration = 3.0)),
        )
        val subject = AudiobookCoordinator(
            manifest,
            AudiobookCoordinator.Source.streaming("https://books.example/api/v2/books/uuid/listen", "secret-token"),
            player = player(client),
            scope = mainScope(),
        )

        assertEquals(AudiobookCoordinator.MoveOutcome.LANDED, onMain(clock) { subject.start(atProgress = 0.0) })

        val request = requests.first()
        assertEquals("https://books.example/api/v2/books/uuid/listen/The%20Outsider.wav", request.url.toString())
        assertEquals("Bearer secret-token", request.header("Authorization"))
        assertEquals("st_token=secret-token", request.header("Cookie"))
        assertEquals(3.0, subject.player.duration, 0.01)
        assertTrue(subject.player.isPlaying)
    }

    /** A stream the server refuses is a track that will not play, and says so. */
    @Test
    fun aRefusedStreamIsUnplayable() {
        val client = OkHttpClient.Builder()
            .addInterceptor { chain ->
                Response.Builder()
                    .request(chain.request())
                    .protocol(Protocol.HTTP_1_1)
                    .code(401)
                    .message("Unauthorized")
                    .body(ByteArray(0).toResponseBody(null))
                    .build()
            }
            .build()
        val manifest = AudiobookManifest(
            metadata = AudiobookManifest.Metadata(title = mapOf("und" to "Streamed")),
            readingOrder = listOf(AudiobookManifest.Track(href = "a.mp3", type = "audio/mpeg", duration = 3.0)),
        )
        val subject = AudiobookCoordinator(
            manifest,
            AudiobookCoordinator.Source.streaming("https://books.example/listen", "expired"),
            player = player(client),
            scope = mainScope(),
        )

        assertEquals(AudiobookCoordinator.MoveOutcome.UNPLAYABLE, onMain(clock) { subject.start(atProgress = 0.0) })
        assertFalse(subject.player.isPlaying)
        assertTrue(subject.player.itemHasFailed)
    }

    /** The location the files source hands the engine is the file the map names. */
    @Test
    fun theFilesSourceOpensItsOwnFile() {
        val file = track("chunk.wav", 2.0)
        val player = player()
        val outcome = onMain(clock) { player.load(AudioLocation.LocalFile(file), "chunk.wav") }
        assertEquals(AudioPlayer.LoadOutcome.LOADED, outcome)
        assertEquals(2.0, player.duration, 0.01)
    }
}
