package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.Session
import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI
import kotlin.time.Duration.Companion.milliseconds

/** A reader restored after the process died asks for its book before the library has been read. */
class ReaderRestoreTest : AppSuite() {
    @Test
    fun waitsForTheLibraryInsteadOfConcludingTheBookIsGone() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val book = SharedFixtures.book("Dracula", uuid = "server-dracula")
        val answer = async { app.awaitServerBook(book.uuid) }

        assertFalse("answered while the app was still launching", waitUntil(300.milliseconds) { answer.isCompleted })

        app.session = Session(URI("http://issa-fixture.test"), TestTokens())
        app.books = listOf(book)
        app.rebuildDerived()
        app.phase = AppModel.Phase.READY
        assertTrue(waitUntil { answer.isCompleted })
        assertEquals(book.uuid, answer.await()?.uuid)
        scope.close()
    }

    @Test
    fun saysGoneOnlyOnceTheLibraryHasLoadedWithoutIt() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val answer = async { app.awaitServerBook("server-dracula") }
        assertFalse(waitUntil(300.milliseconds) { answer.isCompleted })

        app.session = Session(URI("http://issa-fixture.test"), TestTokens())
        app.books = listOf(SharedFixtures.book("Carmilla", uuid = "server-carmilla"))
        app.rebuildDerived()
        app.catalogueApplied = true
        app.phase = AppModel.Phase.READY
        assertTrue(waitUntil { answer.isCompleted })
        assertNull(answer.await())
        scope.close()
    }

    @Test
    fun saysGoneAtOnceWhenThereIsNoAccount() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val answer = async { app.awaitServerBook("server-dracula") }
        app.phase = AppModel.Phase.CHOOSE_SERVER
        assertTrue(waitUntil { answer.isCompleted })
        assertNull(answer.await())
        scope.close()
    }
}
