package com.benjaminissa.issareader.app.media

import android.content.Intent
import android.os.Bundle
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionError
import androidx.media3.session.SessionResult
import com.benjaminissa.issareader.core.sync.CarCatalogue
import com.benjaminissa.issareader.playback.CommandRouter
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.playback.android.SessionMediaIds
import com.benjaminissa.issareader.playback.android.SessionTransport
import com.google.common.util.concurrent.ListenableFuture
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ServiceController
import java.time.Duration
import java.util.concurrent.ExecutionException

/** The service with a stand-in for the app. */
class TestPlaybackService : IssaPlaybackService() {
    override fun makeHost(): MediaHost = checkNotNull(nextHost)

    companion object {
        var nextHost: MediaHost? = null
    }
}

/**
 * The media session and Android Auto, against a stand-in app: the CarPlay
 * scene's behaviour — tabs, rows, empty messages, the rate button, the
 * chapters, the alert on failure — and what Android adds, voice search and
 * a headset's own presses.
 */
@RunWith(RobolectricTestRunner::class)
class IssaPlaybackServiceTest {
    private lateinit var host: FakeHost
    private lateinit var controller: ServiceController<TestPlaybackService>
    private lateinit var service: IssaPlaybackService

    private val dracula = book("Dracula", author = "Bram Stoker", progress = 0.4, positionTimestamp = 900.0, audioDuration = 3600.0)
    private val dune = book("Dune", author = "Frank Herbert", narrated = true, progress = 0.1, positionTimestamp = 100.0)
    private val fresh = book("Frankenstein", author = "Mary Shelley")
    private val silent = book("Silent", ebookOnly = true)
    private val mine = book("Mine", narrated = true, local = true, progress = 0.9, positionTimestamp = 5000.0)

    private fun controllerInfo(pkg: String, version: Int = 0, trusted: Boolean = false): MediaSession.ControllerInfo =
        MediaSession.ControllerInfo.createTestOnlyControllerInfo(pkg, 0, 0, version, 0, trusted, Bundle.EMPTY, true)

    private val car = controllerInfo("com.google.android.projection.gearhead")
    private val stranger = controllerInfo("com.example.snoop")
    private val bluetooth = controllerInfo("com.android.bluetooth")

    @Before
    fun setUp() {
        host = FakeHost(books = listOf(dracula, dune, fresh, silent, mine), downloaded = setOf("dune", "mine"))
        TestPlaybackService.nextHost = host
        controller = Robolectric.buildService(TestPlaybackService::class.java).create()
        service = controller.get()
    }

    @After
    fun tearDown() {
        controller.destroy()
        TestPlaybackService.nextHost = null
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun <T> ListenableFuture<T>.await(): T {
        repeat(50) {
            if (isDone) return get()
            idle()
        }
        return get()
    }

    private val callback get() = service.callback
    private val session get() = service.session

    private fun children(parent: String, browser: MediaSession.ControllerInfo = car): LibraryResult<com.google.common.collect.ImmutableList<MediaItem>> =
        callback.onGetChildren(session, browser, parent, 0, Int.MAX_VALUE, null).await()

    private fun titles(parent: String) = children(parent).value.orEmpty().map { it.mediaMetadata.title.toString() }

    // The tree

    /** The root says search is supported; its children are CarPlay's three tabs, cut to what the car draws. */
    @Test
    fun theRootAndItsTabs() {
        val hints = LibraryParams.Builder().setExtras(Bundle().apply { putInt(AutoBrowseTree.ROOT_CHILDREN_LIMIT, 4) }).build()
        val root = callback.onGetLibraryRoot(session, car, hints).await()
        assertEquals(AutoBrowseTree.ROOT, root.value?.mediaId)
        assertTrue(checkNotNull(root.params).extras.getBoolean(AutoBrowseTree.SEARCH_SUPPORTED))
        val tabs = children(AutoBrowseTree.ROOT).value.orEmpty()
        assertEquals(listOf("Recent", "Library", "Downloaded"), tabs.map { it.mediaMetadata.title.toString() })
        assertTrue(tabs.all { it.mediaMetadata.artworkUri?.scheme == "android.resource" })

        val narrow = controllerInfo("com.google.android.projection.gearhead", version = 0, trusted = true)
        val two = LibraryParams.Builder().setExtras(Bundle().apply { putInt(AutoBrowseTree.ROOT_CHILDREN_LIMIT, 2) }).build()
        callback.onGetLibraryRoot(session, narrow, two).await()
        assertEquals(2, children(AutoBrowseTree.ROOT, narrow).value?.size)
    }

    /** The shelves hold what CarPlay's did: audio only, the reader's own files never. */
    @Test
    fun theShelves() {
        assertEquals(listOf("Dracula", "Dune"), titles(AutoBrowseTree.shelfId(CarCatalogue.Shelf.RECENT)))
        assertEquals(listOf("Dracula", "Dune", "Frankenstein"), titles(AutoBrowseTree.shelfId(CarCatalogue.Shelf.LIBRARY)))
        assertEquals(listOf("Dune"), titles(AutoBrowseTree.shelfId(CarCatalogue.Shelf.DOWNLOADED)))
        val row = children(AutoBrowseTree.shelfId(CarCatalogue.Shelf.RECENT)).value.orEmpty().first()
        assertEquals("Bram Stoker · 36m left", row.mediaMetadata.subtitle.toString())
        assertEquals("content", row.mediaMetadata.artworkUri?.scheme)
    }

    /** An empty shelf says so. */
    @Test
    fun emptyShelves() {
        host.books = emptyList()
        for (shelf in CarCatalogue.Shelf.entries) {
            assertEquals(listOf(shelf.emptyMessage), titles(AutoBrowseTree.shelfId(shelf)))
        }
    }

    /** A library that changes is announced, so a car connected before the phone loaded does not sit on an empty list. */
    @Test
    fun aChangedLibraryIsAnnounced() {
        host.books = emptyList()
        assertEquals(listOf("Nothing started yet"), titles(AutoBrowseTree.shelfId(CarCatalogue.Shelf.RECENT)))
        host.books = listOf(dracula)
        host.libraryChanged()
        assertEquals(listOf("Dracula"), titles(AutoBrowseTree.shelfId(CarCatalogue.Shelf.RECENT)))
    }

    /** Signed out, the car says where to sign in, as an authentication error. */
    @Test
    fun signedOut() {
        host.access = MediaHost.Access.SIGNED_OUT
        val result = children(AutoBrowseTree.shelfId(CarCatalogue.Shelf.LIBRARY))
        assertEquals(SessionError.ERROR_SESSION_AUTHENTICATION_EXPIRED, result.resultCode)
        assertEquals(IssaPlaybackService.SIGN_IN_MESSAGE, result.sessionError?.message)
    }

    /** An app that merely binds the service is not shown the reader's library. */
    @Test
    fun strangersCannotBrowse() {
        assertEquals(SessionError.ERROR_PERMISSION_DENIED, children(AutoBrowseTree.shelfId(CarCatalogue.Shelf.LIBRARY), stranger).resultCode)
        assertEquals(LibraryResult.RESULT_SUCCESS, children(AutoBrowseTree.shelfId(CarCatalogue.Shelf.LIBRARY), bluetooth).resultCode)
    }

    // Voice search

    @Test
    fun searchResults() {
        val searched = callback.onSearch(session, car, "Bram Stoker", null).await()
        assertEquals(LibraryResult.RESULT_SUCCESS, searched.resultCode)
        val results = callback.onGetSearchResult(session, car, "Bram Stoker", 0, 10, null).await()
        assertEquals(listOf(SessionMediaIds.book("dracula")), results.value.orEmpty().map { it.mediaId })
        // A text-only book is never a result, nor the reader's own.
        assertTrue(callback.onGetSearchResult(session, car, "Silent", 0, 10, null).await().value.orEmpty().isEmpty())
        assertTrue(callback.onGetSearchResult(session, car, "Mine", 0, 10, null).await().value.orEmpty().isEmpty())
    }

    /** "Play Dracula by Bram Stoker": the best match plays, through the app. */
    @Test
    fun playFromSearchPlaysTheBestMatch() {
        val request = MediaItem.Builder()
            .setRequestMetadata(MediaItem.RequestMetadata.Builder().setSearchQuery("Dracula by Bram Stoker").build())
            .build()
        val resolved = callback.onSetMediaItems(session, car, mutableListOf(request), C.INDEX_UNSET, C.TIME_UNSET).await()
        assertEquals(listOf(SessionMediaIds.book("dracula")), resolved.mediaItems.map { it.mediaId })
        assertEquals(C.TIME_UNSET, resolved.startPositionMs)
        // What Media3 does next: set it on the player, which starts the book.
        service.player.setMediaItems(resolved.mediaItems, resolved.startIndex, resolved.startPositionMs)
        idle()
        assertEquals(listOf("dracula"), host.started)
        assertNull(service.shownError)
    }

    /** An empty query resumes the most recent book. */
    @Test
    fun anEmptyQueryResumes() {
        val request = MediaItem.Builder().setRequestMetadata(MediaItem.RequestMetadata.Builder().setSearchQuery("").build()).build()
        val resolved = callback.onSetMediaItems(session, car, mutableListOf(request), C.INDEX_UNSET, C.TIME_UNSET).await()
        assertEquals(listOf(SessionMediaIds.book("dracula")), resolved.mediaItems.map { it.mediaId })
    }

    /** A query matching nothing is said on the car's screen, and plays nothing. */
    @Test
    fun aSearchThatFindsNothing() {
        val request = MediaItem.Builder().setRequestMetadata(MediaItem.RequestMetadata.Builder().setSearchQuery("Moby Dick").build()).build()
        val future = callback.onSetMediaItems(session, car, mutableListOf(request), C.INDEX_UNSET, C.TIME_UNSET)
        try {
            future.await()
            throw AssertionError("expected no match")
        } catch (e: ExecutionException) {
            assertTrue(e.cause is IssaPlaybackService.Unplayable)
        }
        assertEquals("Nothing in your library matches “Moby Dick”.", service.shownError?.message)
        assertTrue(host.started.isEmpty())
    }

    /** What the store's own index finds is the fallback, filtered to what the car may play. */
    @Test
    fun theStoreIsTheFallback() {
        host.storeResults = listOf(silent, fresh, mine)
        val request = MediaItem.Builder().setRequestMetadata(MediaItem.RequestMetadata.Builder().setSearchQuery("gothic horror").build()).build()
        val resolved = callback.onSetMediaItems(session, car, mutableListOf(request), C.INDEX_UNSET, C.TIME_UNSET).await()
        assertEquals(listOf(SessionMediaIds.book("frankenstein")), resolved.mediaItems.map { it.mediaId })
    }

    // Playing

    /** A row tapped in the car starts its book; a failure is said on the car's screen, as CarPlay's alert said it. */
    @Test
    fun aFailureIsShownInTheCar() {
        val message = "That book's audio would not play. Try downloading it again."
        host.startFailures = mapOf("dune" to message)
        val resolved = callback.onSetMediaItems(session, car, mutableListOf(MediaItem.Builder().setMediaId(SessionMediaIds.book("dune")).build()), 0, C.TIME_UNSET).await()
        service.player.setMediaItems(resolved.mediaItems, resolved.startIndex, resolved.startPositionMs)
        idle()
        assertEquals(listOf("dune"), host.started)
        assertEquals(message, service.shownError?.message)
        assertEquals(SessionError.ERROR_UNKNOWN, service.shownError?.errorCode)
    }

    /** A book that has left the library says so. */
    @Test
    fun aBookThatHasGone() {
        val future = callback.onSetMediaItems(session, car, mutableListOf(MediaItem.Builder().setMediaId(SessionMediaIds.book("gone")).build()), 0, C.TIME_UNSET)
        runCatching { future.await() }
        assertEquals(IssaPlaybackService.BOOK_GONE, service.shownError?.message)
    }

    /** Signed out, playing says where to sign in, as an authentication error. */
    @Test
    fun signedOutPlaying() {
        host.access = MediaHost.Access.SIGNED_OUT
        val future = callback.onSetMediaItems(session, car, mutableListOf(MediaItem.Builder().setMediaId(SessionMediaIds.book("dracula")).build()), 0, C.TIME_UNSET)
        runCatching { future.await() }
        assertEquals(SessionError.ERROR_SESSION_AUTHENTICATION_EXPIRED, service.shownError?.errorCode)
        assertEquals(IssaPlaybackService.SIGN_IN_MESSAGE, service.shownError?.message)
        assertTrue(host.started.isEmpty())
    }

    /** The play button with nothing loaded resumes the last book listened to. */
    @Test
    fun playbackResumption() {
        val resumed = callback.onPlaybackResumption(session, car, true).await()
        assertEquals(listOf(SessionMediaIds.book("dracula")), resumed.mediaItems.map { it.mediaId })
        // What is loaded now wins over the top of Recent.
        host.playing = MediaHost.Playing(dune, isPlaying = false, rate = 1f)
        val loaded = callback.onPlaybackResumption(session, car, true).await()
        assertEquals(listOf(SessionMediaIds.book("dune")), loaded.mediaItems.map { it.mediaId })
    }

    // Now Playing

    private fun publish(chapter: String = "Two") {
        host.sink?.publish(CommandRouter.nowPlaying("Dune", "Frank Herbert", chapter, elapsed = 30.0, duration = 300.0, rate = 1f), null)
    }

    /** The chapters are the queue, the chapter playing marked; picking one plays it. */
    @Test
    fun chaptersAreTheQueue() {
        assertNotNull("the service is Now Playing's sink while it runs", host.sink)
        host.playing = MediaHost.Playing(dune, isPlaying = true, rate = 1f)
        host.chapterTitles = listOf("One", "Two", "Three")
        host.chapterIndex = 1
        publish()
        val player = service.player
        assertEquals(3, player.currentTimeline.windowCount)
        assertEquals(1, player.currentMediaItemIndex)
        assertEquals("Dune", player.mediaMetadata.title.toString())
        assertEquals("Two", player.mediaMetadata.albumTitle.toString())
        assertEquals("content", player.mediaMetadata.artworkUri?.scheme)
        player.seekTo(2, C.TIME_UNSET)
        idle()
        assertEquals(listOf(2), host.chaptersPlayed)
    }

    /** Nothing published is nothing playing. */
    @Test
    fun detachingClears() {
        host.playing = MediaHost.Playing(dune, isPlaying = true, rate = 1f)
        publish()
        host.sink?.publish(null, null)
        assertTrue(service.player.currentTimeline.isEmpty)
    }

    /** CarPlay's rate button: 1 → 1.25 → 1.5 → 1.75 → 2 → 1, and the button says the speed. */
    @Test
    fun theRateButtonCycles() {
        repeat(5) {
            val result = callback.onCustomCommand(session, car, SessionTransport.cycleRate, Bundle.EMPTY).await()
            assertEquals(SessionResult.RESULT_SUCCESS, result.resultCode)
            if (it == 0) assertEquals("Speed 1.25×", session.mediaButtonPreferences.last().displayName.toString())
        }
        assertEquals(listOf(1.25, 1.5, 1.75, 2.0, 1.0), host.rateCycles)
        assertEquals("Speed 1×", session.mediaButtonPreferences.last().displayName.toString())
    }

    /** The phone draws the skips; the car's connecting draws the track pair, by the bindings. */
    @Test
    fun theTransportFollowsTheSurface() {
        val phone = session.mediaButtonPreferences.mapNotNull { it.playerCommand.takeIf { c -> c != androidx.media3.common.Player.COMMAND_INVALID } }
        assertEquals(listOf(androidx.media3.common.Player.COMMAND_SEEK_BACK, androidx.media3.common.Player.COMMAND_SEEK_FORWARD), phone)
        host.router.activeSurface = com.benjaminissa.issareader.playback.ControlSurface.CAR
        idle()
        assertTrue(session.mediaButtonPreferences.none { it.playerCommand == androidx.media3.common.Player.COMMAND_SEEK_BACK })
    }

    // The car's comings and goings

    /** Android Auto's controller connecting is a witness that a car is there, and its going that it has gone. */
    @Test
    fun theCarsControllerIsAWitness() {
        callback.onConnect(session, car)
        assertEquals(listOf(true), host.carChanges)
        callback.onDisconnected(session, car)
        assertEquals(listOf(true, false), host.carChanges)
        callback.onConnect(session, bluetooth)
        assertEquals(listOf(true, false), host.carChanges)
    }

    // Hardware keys

    private fun key(code: Int, action: Int): Intent {
        val now = SystemClock.uptimeMillis()
        return Intent(Intent.ACTION_MEDIA_BUTTON).putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(now, now, action, code, 0))
    }

    /**
     * A headset's double press is the wheel's next under the bindings — thirty
     * seconds on the shipped ones — not Media3's next chapter.
     */
    @Test
    fun aHeadsetDoublePressIsNotAChapter() {
        val actions = mutableListOf<PlaybackAction>()
        host.router.onAction = { actions += it }
        host.playing = MediaHost.Playing(dune, isPlaying = true, rate = 1f)
        host.chapterTitles = listOf("One", "Two", "Three")
        host.chapterIndex = 0
        publish("One")
        repeat(2) {
            assertTrue(callback.onMediaButtonEvent(session, bluetooth, key(KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.ACTION_DOWN)))
            assertTrue(callback.onMediaButtonEvent(session, bluetooth, key(KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.ACTION_UP)))
        }
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertEquals(listOf(PlaybackAction.SKIP_FORWARD), actions)
        assertTrue(host.chaptersPlayed.isEmpty())
    }

    /** With nothing loaded a key is Media3's, whose play resumes the last book. */
    @Test
    fun aKeyWithNothingLoadedIsMedia3s() {
        assertFalse(callback.onMediaButtonEvent(session, bluetooth, key(KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.ACTION_DOWN)))
    }
}
