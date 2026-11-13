package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.LifecycleServer
import com.benjaminissa.issareader.app.PlaybackSettingsForTests
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.waitUntil
import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Listen on a book while another book's start is still waiting on the server.
 * The start runs on the app's scope, so leaving the first book's page no
 * longer ends it.
 */
class ListenSupersedeTest : AppSuite() {
    private val settings = PlaybackSettingsForTests.make()

    /** A start for a different book takes over: the one in flight is cancelled and the new one runs. */
    @Test
    fun aStartForAnotherBookSupersedesTheOneInFlight() = mainTest {
        val fixture = AccountExitTest.signedInAsA()
        try {
            val app = fixture.app
            val firstManifest = LifecycleServer.manifestPath(LifecycleServer.first)
            val secondManifest = LifecycleServer.manifestPath(LifecycleServer.second)
            fixture.server.hold(firstManifest)
            fixture.server.hold(secondManifest)
            val nowPlaying = NowPlayingController(fixture.scope)
            val first = SharedFixtures.book("First", uuid = LifecycleServer.first, audiobook = true)
            val second = SharedFixtures.book("Second", uuid = LifecycleServer.second, audiobook = true)

            val starting = fixture.scope.async { app.startListening(first, nowPlaying, settings) }
            assertTrue(waitUntil { fixture.server.held(firstManifest) == 1 })

            val superseding = fixture.scope.async { app.startListening(second, nowPlaying, settings) }

            assertTrue("the second book's start never reached the server", waitUntil { fixture.server.held(secondManifest) == 1 })
            assertTrue("the first start was left running", waitUntil { starting.isCancelled })
            assertEquals(second.uuid, app.startingListeningBook)
            assertFalse("the second start was dropped", superseding.isCompleted)

            fixture.server.release(secondManifest)
            fixture.server.release(firstManifest)
            superseding.await()
        } finally {
            fixture.tearDown()
        }
    }

    /** A repeat tap for the same book is still ignored: one manifest request, one start. */
    @Test
    fun aRepeatForTheSameBookIsIgnored() = mainTest {
        val fixture = AccountExitTest.signedInAsA()
        try {
            val app = fixture.app
            val manifest = LifecycleServer.manifestPath(LifecycleServer.first)
            fixture.server.hold(manifest)
            val nowPlaying = NowPlayingController(fixture.scope)
            val book = SharedFixtures.book("First", uuid = LifecycleServer.first, audiobook = true)

            val starting = fixture.scope.async { app.startListening(book, nowPlaying, settings) }
            assertTrue(waitUntil { fixture.server.held(manifest) == 1 })

            app.startListening(book, nowPlaying, settings)

            assertFalse("the first start was cancelled by its own repeat", starting.isCancelled)
            assertEquals(1, fixture.server.held(manifest))
            fixture.server.release(manifest)
            starting.await()
        } finally {
            fixture.tearDown()
        }
    }
}
