package com.benjaminissa.issareader.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.time.Duration.Companion.seconds

/**
 * Waiting for work, or for a deadline: the one bounded wait, shared by
 * sign-out's revoke and the search index's clear. Ported from
 * `CoreBoundedWaitTests` in `BoundedWaitTests.swift`.
 */
class BoundedWaitTest {
    /** Slow work is waited for no longer than the limit, and still finishes. */
    @Test
    fun slowWork() = runBlocking {
        // The deadline passes at once and the work is held until the test lets
        // it go: no wall clock, so a busy run cannot decide it.
        val done = AtomicBoolean(false)
        val gate = CompletableDeferred<Unit>()
        val finished = BoundedWait.run(30.seconds, sleep = { }) {
            gate.await()
            done.set(true)
        }
        assertFalse("the caller was held by the work", finished)
        assertFalse(done.get())
        gate.complete(Unit)
        repeat(200) { if (!done.get()) delay(20) }
        assertTrue("the work has to run to its end after the wait gives up", done.get())
    }

    /** Work that finishes in time is waited for. */
    @Test
    fun quickWork() = runBlocking {
        val done = AtomicBoolean(false)
        val finished = BoundedWait.run(5.seconds) { done.set(true) }
        assertTrue(finished)
        assertTrue(done.get())
    }

    /**
     * The deadline's timer is let go of once the work has won. The copy the
     * app kept never let go of its timer, so every sign-out left a detached
     * sleep running out its full limit to a no-op.
     */
    @Test
    fun timerIsCancelled() = runBlocking {
        val cancelled = AtomicBoolean(false)
        val finished = BoundedWait.run(30.seconds, sleep = { limit ->
            try {
                delay(limit)
            } catch (e: CancellationException) {
                cancelled.set(true)
                throw e
            }
        }) {}
        assertTrue(finished)
        repeat(100) { if (!cancelled.get()) delay(20) }
        assertTrue("the timer was left sleeping after the work finished", cancelled.get())
    }
}
