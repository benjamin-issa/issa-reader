package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.core.BoundedWait
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * The wait an account's departure gives the launcher. Ported from
 * `BoundedWaitTests.swift`, where the caller was Spotlight's clear; here it is
 * [ShortcutPublisher.clear].
 */
class BoundedWaitTest : AppSuite() {
    /** Slow work is waited for no longer than the limit, and still finishes. */
    @Test
    fun slowWorkIsNotWaitedFor() = mainTest {
        val done = AtomicBoolean(false)
        val started = System.nanoTime()

        val finished = BoundedWait.run(200.milliseconds) {
            delay(5.seconds)
            done.set(true)
        }

        assertFalse(finished)
        assertTrue("the caller was held by the work", System.nanoTime() - started < 3.seconds.inWholeNanoseconds)
        assertFalse(done.get())
        repeat(200) { if (!done.get()) delay(50) }
        assertTrue("the work has to run to its end after the wait gives up", done.get())
    }

    /** Work that finishes in time is waited for. */
    @Test
    fun quickWorkIsWaitedFor() = mainTest {
        val done = AtomicBoolean(false)
        val finished = BoundedWait.run(5.seconds) { done.set(true) }
        assertTrue(finished)
        assertTrue(done.get())
    }

    /** The caller in production: whatever the launcher does, an account's departure is not held past the limit. */
    @Test
    fun shortcutClearIsBounded() = mainTest {
        val stuck = CompletableDeferred<Unit>()
        val backend = object : ShortcutBackend {
            override val capacity = 4
            override suspend fun replace(shortcuts: List<BookShortcut>) = Unit

            // A launcher that never answers.
            override suspend fun removeAll() = stuck.await()
        }
        val clearWait = 1.seconds
        val publisher = ShortcutPublisher(backend, SharedFixtures.scratchDefaults(), clearWait = clearWait)
        val started = System.nanoTime()
        publisher.clear()
        assertTrue(System.nanoTime() - started < (clearWait + 2.seconds).inWholeNanoseconds)
        stuck.complete(Unit)
    }
}
