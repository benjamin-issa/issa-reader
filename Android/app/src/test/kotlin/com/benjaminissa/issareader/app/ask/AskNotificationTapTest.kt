package com.benjaminissa.issareader.app.ask

import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.model.SignOutCentre
import com.benjaminissa.issareader.ask.AskIndexStore
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.core.auth.TokenPersisting
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.net.URI

/**
 * Tapping "Your answer is ready". Swift's `AskNotificationTapTests`.
 *
 * The open reader takes the tap through `reopenRequest` — its handler opens the
 * answer — so a request for the book has nothing left to do. The delegate
 * armed one anyway, and a request left waiting opened the book again, unasked,
 * the next time something consumed it.
 */
@RunWith(RobolectricTestRunner::class)
class AskNotificationTapTest {
    private val bookUuid = "22222222-2222-4222-8222-222222222222"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val defaults = InMemoryKeyValueStore()
    private val directory = AskHarness.temporaryDirectory()
    private val coordinator = AskCoordinator(
        settings = PlaybackSettings(defaults, SignOutCentre()),
        platform = CountingPlatform(),
        defaults = defaults,
        scope = scope,
        store = AskIndexStore(directory),
        centre = SignOutCentre(),
    )
    private val app = AppModel(keychain = NoTokens(), defaults = defaults, notificationCentre = SignOutCentre(), scope = scope)
    private val localRequests = LocalBookRequests()
    private val router = AskNotificationRouter(coordinator, app, local = null, localRequests = localRequests, scope = scope)

    @After
    fun tearDown() {
        scope.cancel()
        directory.deleteRecursively()
    }

    @Test
    fun `a tap for the book already being read asks only its reader`() {
        app.setReaderVisible(bookUuid, true)
        router.open(bookUuid)

        assertEquals("the reader on screen opens the answer", bookUuid, coordinator.reopenRequest)
        assertNull("a request left waiting opens the book again later", app.pendingBook)
        app.setReaderVisible(bookUuid, false)
    }

    @Test
    fun `a tap for a book not on screen goes by the request`() {
        app.setReaderVisible("some-other-book", true)
        router.open(bookUuid)

        assertEquals(bookUuid, app.pendingBook?.uuid)
        app.setReaderVisible("some-other-book", false)
    }

    @Test
    fun `a tap for a book not on screen still opens it`() {
        app.setReaderVisible("some-other-book", true)
        router.open(bookUuid)

        assertEquals(bookUuid, coordinator.reopenRequest)
        assertEquals(AppModel.PendingBook(bookUuid, AppModel.PendingBook.Destination.READ), app.pendingBook)
        app.setReaderVisible("some-other-book", false)
    }

    @Test
    fun `a tap with no reader up opens the book`() {
        router.open(bookUuid)

        assertEquals(AppModel.PendingBook(bookUuid, AppModel.PendingBook.Destination.READ), app.pendingBook)
    }

    // Android: the notification's link, and the reader's own books

    /** The notification carries `issareader://ask/<uuid>`; the activity hands it to the app, which hands it here. */
    @Test
    fun `the notification's link reaches the router through the app`() {
        app.answerLinks = router::open
        assertEquals(true, app.open(URI(AskNotifier.link(bookUuid))))

        assertEquals(bookUuid, coordinator.reopenRequest)
        assertEquals(AppModel.PendingBook(bookUuid, AppModel.PendingBook.Destination.READ), app.pendingBook)
    }

    @Test
    fun `with nothing to route it, the link still opens the book`() {
        assertEquals(true, app.open(URI(AskNotifier.link(bookUuid))))
        assertEquals(AppModel.PendingBook(bookUuid, AppModel.PendingBook.Destination.READ), app.pendingBook)
    }

    /** A book from the reader's files is not in the server's catalogue, whose inbox would wait for it for ever. */
    @Test
    fun `a tap for one of the reader's own books is left for the local route`() {
        app.localBookUuids = { setOf(bookUuid) }
        router.open(bookUuid)

        assertNull(app.pendingBook)
        assertEquals(bookUuid, localRequests.take())
        assertNull("taken once", localRequests.take())
    }
}

/** A token store that never touches the Keystore. */
private class NoTokens : TokenPersisting {
    override fun read(account: String): String? = null
    override fun write(token: String, account: String): Boolean = true
    override fun delete(account: String): Boolean = true
}
