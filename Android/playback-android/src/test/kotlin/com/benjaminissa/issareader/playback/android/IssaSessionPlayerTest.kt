package com.benjaminissa.issareader.playback.android

import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import com.benjaminissa.issareader.playback.CommandMap
import com.benjaminissa.issareader.playback.CommandRouter
import com.benjaminissa.issareader.playback.ControlSurface
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.playback.PlaybackControl
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * The session's player: what it presents, and where each command goes.
 *
 * No Swift counterpart as a type — iOS published a dictionary to
 * `MPNowPlayingInfoCenter` and registered handlers on `MPRemoteCommandCenter`
 * — but every rule here is one of `RemoteCommandCenter`'s or the CarPlay
 * scene's, restated for Media3: the queue is CarPlay's Up Next, the track pair
 * is the wheel, and nothing reaches the engine except through the router.
 */
@RunWith(RobolectricTestRunner::class)
class IssaSessionPlayerTest {
    private val actions = mutableListOf<PlaybackAction>()
    private val seeks = mutableListOf<Double>()
    private val rates = mutableListOf<Float>()
    private val chaptersPlayed = mutableListOf<Int>()
    private val started = mutableListOf<List<String>>()
    private var surface: ControlSurface? = null
    private var start: SettableFuture<Unit>? = null

    private lateinit var router: CommandRouter
    private lateinit var player: IssaSessionPlayer

    private val delegate = object : IssaSessionPlayer.Delegate {
        override fun requestSurface(): ControlSurface? = surface

        override fun setMediaItems(items: List<MediaItem>, startIndex: Int, startPositionMs: Long): ListenableFuture<*> {
            started += items.map { it.mediaId }
            return start ?: Futures.immediateVoidFuture()
        }

        override fun playChapter(index: Int): ListenableFuture<*> {
            chaptersPlayed += index
            return Futures.immediateVoidFuture()
        }
    }

    private fun build(map: CommandMap = CommandMap()) {
        router = CommandRouter(map)
        router.onAction = { actions += it }
        router.onSeek = { seeks += it }
        router.onRateChange = { rates += it }
        router.activate()
        player = IssaSessionPlayer(router, delegate)
    }

    @Before
    fun setUp() = build()

    @After
    fun tearDown() = player.release()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun presentation(
        chapters: List<String> = listOf("One", "Two", "Three"),
        chapterIndex: Int? = 1,
        isPlaying: Boolean = true,
        effectiveRate: Float = 1.5f,
    ) = SessionPresentation(
        bookId = "dracula",
        title = "Dracula",
        artist = "Bram Stoker",
        chapter = chapters.getOrNull(chapterIndex ?: 0),
        elapsed = 125.0,
        duration = 600.0,
        isPlaying = isPlaying,
        effectiveRate = effectiveRate,
        rate = 1.5f,
        chapters = chapters,
        chapterIndex = chapterIndex,
    )

    /** Nothing playing is an empty, idle session: nothing for the lock screen to draw. */
    @Test
    fun nothingPlayingIsIdle() {
        assertEquals(Player.STATE_IDLE, player.playbackState)
        assertTrue(player.currentTimeline.isEmpty)
        assertFalse(player.playWhenReady)
    }

    /** The chapters are the queue, with the one playing as the current item. */
    @Test
    fun chaptersAreTheQueue() {
        player.present(presentation())
        val timeline = player.currentTimeline
        assertEquals(3, timeline.windowCount)
        val titles = (0 until 3).map { timeline.getWindow(it, androidx.media3.common.Timeline.Window()).mediaItem.mediaMetadata.title.toString() }
        assertEquals(listOf("One", "Two", "Three"), titles)
        assertEquals(1, player.currentMediaItemIndex)
        assertEquals(SessionMediaIds.chapter("dracula", 1), player.currentMediaItem?.mediaId)
        assertEquals(IssaSessionPlayer.QUEUE_TITLE, player.playlistMetadata.title.toString())
    }

    /** Now Playing: the book as the title, the byline as the artist, the chapter as the album. */
    @Test
    fun nowPlayingNamesTheBookAndTheChapter() {
        player.present(presentation())
        val metadata = player.mediaMetadata
        assertEquals("Dracula", metadata.title.toString())
        assertEquals("Bram Stoker", metadata.artist.toString())
        assertEquals("Two", metadata.albumTitle.toString())
        assertEquals(600_000L, player.duration)
        assertEquals(125_000L, player.contentPosition)
        assertEquals(1.5f, player.playbackParameters.speed)
        assertTrue(player.playWhenReady)
        assertEquals(Player.STATE_READY, player.playbackState)
    }

    /**
     * Through a stall the listener still wants it playing, and the session
     * says buffering: the clock stops and the button does not offer ▶.
     */
    @Test
    fun aStallIsBufferingNotPaused() {
        player.present(presentation(effectiveRate = 0f))
        assertTrue(player.playWhenReady)
        assertEquals(Player.STATE_BUFFERING, player.playbackState)
        assertFalse(player.isPlaying)
    }

    /** A book with no chapter list is still one item, so the car has something playing. */
    @Test
    fun noChaptersIsOneItem() {
        player.present(presentation(chapters = emptyList(), chapterIndex = null))
        assertEquals(1, player.currentTimeline.windowCount)
        assertEquals(0, player.currentMediaItemIndex)
    }

    /** Play and pause are discrete, through the router. */
    @Test
    fun playAndPauseAreDiscrete() {
        player.present(presentation(isPlaying = false, effectiveRate = 0f))
        player.play()
        player.pause()
        assertEquals(listOf(PlaybackAction.PLAY, PlaybackAction.PAUSE), actions)
    }

    /** The system's skip buttons are the tap controls: thirty on, fifteen back by default. */
    @Test
    fun skipsAreTheTapControls() {
        player.present(presentation())
        player.seekForward()
        player.seekBack()
        assertEquals(listOf(PlaybackAction.SKIP_FORWARD, PlaybackAction.SKIP_BACKWARD), actions)
    }

    /**
     * "Next" is the wheel's `»` under the bindings — never Media3's next
     * chapter. From the car, the car's binding (thirty seconds) answers; from
     * the phone, which binds nothing to the wheel, nothing is offered.
     */
    @Test
    fun nextIsTheWheelUnderTheBindings() {
        player.present(presentation())
        surface = ControlSurface.CAR
        player.seekToNext()
        player.seekToPrevious()
        assertEquals(listOf(PlaybackAction.SKIP_FORWARD, PlaybackAction.SKIP_BACKWARD), actions)
        assertTrue(chaptersPlayed.isEmpty())

        actions.clear()
        surface = ControlSurface.PHONE
        player.seekToNext()
        assertTrue(actions.isEmpty())
    }

    /** At the last chapter a wheel press still reaches the bindings: Media3 has no next item, the car still has a wheel. */
    @Test
    fun theWheelWorksOnTheLastChapter() {
        val map = CommandMap().withBinding(PlaybackAction.NEXT_CHAPTER, PlaybackControl.WHEEL_NEXT, ControlSurface.CAR)
        player.release()
        build(map)
        player.present(presentation(chapterIndex = 2))
        surface = ControlSurface.CAR
        player.seekToNext()
        assertEquals(listOf(PlaybackAction.NEXT_CHAPTER), actions)
    }

    /** Picking a chapter from the queue plays it; dragging the bar scrubs within the span. */
    @Test
    fun theQueuePlaysAChapterAndTheBarScrubs() {
        player.present(presentation())
        player.seekTo(2, C.TIME_UNSET)
        assertEquals(listOf(2), chaptersPlayed)
        player.seekTo(42_000)
        assertEquals(listOf(42.0), seeks)
    }

    /** A speed from the system's own control goes to the router, which clamps and saves it. */
    @Test
    fun speedGoesThroughTheRouter() {
        player.present(presentation())
        player.setPlaybackSpeed(2.0f)
        assertEquals(listOf(2.0f), rates)
    }

    /**
     * A controller setting a book starts it through the app, and a play sent
     * meanwhile is not passed on: the start plays by itself, and passing it on
     * would resume whatever was there before.
     */
    @Test
    fun aStartIsTheAppsAndPlayWaitsForIt() {
        val pending = SettableFuture.create<Unit>()
        start = pending
        player.setMediaItem(MediaItem.Builder().setMediaId(SessionMediaIds.book("dracula")).build())
        player.prepare()
        player.play()
        assertEquals(listOf(listOf(SessionMediaIds.book("dracula"))), started)
        assertTrue(actions.isEmpty())

        pending.set(Unit)
        idle()
        player.present(presentation())
        player.pause()
        assertEquals(listOf(PlaybackAction.PAUSE), actions)
    }

    /** The intervals the system advertises follow the command map's. */
    @Test
    fun intervalsFollowTheMap() {
        player.setSkipIntervals(10.0, 45.0)
        assertEquals(10_000L, player.seekBackIncrement)
        assertEquals(45_000L, player.seekForwardIncrement)
    }

    /** The ids round-trip, and a malformed one names nothing. */
    @Test
    fun mediaIds() {
        assertEquals("dracula", SessionMediaIds.bookUuid(SessionMediaIds.book("dracula")))
        assertEquals("dracula" to 3, SessionMediaIds.chapter(SessionMediaIds.chapter("dracula", 3)))
        assertEquals(null, SessionMediaIds.bookUuid("chapter/dracula/3"))
        assertEquals(null, SessionMediaIds.chapter("chapter/dracula/x"))
        assertEquals(null, SessionMediaIds.chapter("chapter//3"))
        assertEquals(null, SessionMediaIds.bookUuid("book/"))
    }
}
