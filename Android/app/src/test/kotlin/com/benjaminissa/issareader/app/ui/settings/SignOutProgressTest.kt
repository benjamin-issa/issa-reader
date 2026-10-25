package com.benjaminissa.issareader.app.ui.settings

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * One sign-out at a time, whichever screen asks: Swift's
 * `MacDecisionsTests.oneSignOutAtATime`. A Settings screen built again during
 * a sign-out had forgotten it, and offered a second.
 */
class SignOutProgressTest {
    @Test
    fun `a second sign-out is refused while one runs, whichever screen asks`() = runBlocking {
        val progress = SignOutProgress()
        val hold = CompletableDeferred<Unit>()
        val started = CompletableDeferred<Unit>()
        val first = async {
            progress.run {
                started.complete(Unit)
                hold.await()
            }
        }
        started.await()
        assertTrue(progress.isRunning)
        assertFalse("a second sign-out started behind the first", progress.run {})
        hold.complete(Unit)
        assertTrue(first.await())
        assertFalse(progress.isRunning)
    }

    /** One that ends with the app still there must not leave the button dead. */
    @Test
    fun `a sign-out that fails still lets the button come back`() = runBlocking {
        val progress = SignOutProgress()
        runCatching { progress.run { error("the server went away") } }
        assertFalse(progress.isRunning)
        assertTrue(progress.run {})
    }
}
