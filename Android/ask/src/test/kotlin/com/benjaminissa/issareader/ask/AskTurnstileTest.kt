package com.benjaminissa.issareader.ask

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Collections

/**
 * The turn itself, without an engine or a model around it: a waiter really
 * waits, waiters are let through in the order they arrived, a throwing body
 * still releases — a body that throws without releasing wedges every later
 * question in the process — and `ifFree` skips rather than queues.
 */
class AskTurnstileTest {
    /** Somewhere for the bodies to record what happened, in order. */
    private val trace: MutableList<String> = Collections.synchronizedList(ArrayList())

    /** A gate a test can hold a turn open with, without racing a sleep. */
    private class Gate {
        private val opened = CompletableDeferred<Unit>()
        private val arrived = CompletableDeferred<Unit>()

        suspend fun wait() {
            arrived.complete(Unit)
            opened.await()
        }

        /** Suspends until somebody is actually inside [wait]. */
        suspend fun waitUntilHeld() = arrived.await()

        fun open() {
            opened.complete(Unit)
        }
    }

    @Test
    fun `a second body waits for the first to finish`() = runBlocking(Dispatchers.Default) {
        val turnstile = AskTurnstile()
        val gate = Gate()

        val first = launch {
            turnstile.withTurn {
                trace.add("first in")
                gate.wait()
                trace.add("first out")
            }
        }
        gate.waitUntilHeld()

        val second = launch { turnstile.withTurn { trace.add("second in") } }
        delay(50)
        assertEquals(listOf("first in"), trace.toList())

        gate.open()
        first.join()
        second.join()
        assertEquals(listOf("first in", "first out", "second in"), trace.toList())
    }

    @Test
    fun `waiters are let through in the order they arrived`() = runBlocking(Dispatchers.Default) {
        val turnstile = AskTurnstile()
        val gate = Gate()

        val holder = launch { turnstile.withTurn { gate.wait() } }
        gate.waitUntilHeld()

        // Twenty milliseconds between each, which is a hope about scheduling
        // rather than a guarantee — but the thing hoped for is a single hop.
        val waiters = (1..4).map { index ->
            val job = launch { turnstile.withTurn { trace.add("$index") } }
            delay(20)
            job
        }

        gate.open()
        holder.join()
        waiters.forEach { it.join() }
        assertEquals(listOf("1", "2", "3", "4"), trace.toList())
    }

    @Test
    fun `a body that throws still gives the turn back`() = runBlocking {
        class Boom : Exception()
        val turnstile = AskTurnstile()
        try {
            turnstile.withTurn<Unit> { throw Boom() }
            fail("the body's failure must come out")
        } catch (_: Boom) {
        }
        // If the throw had kept the turn, this would never run.
        assertTrue(turnstile.ifFree {})
    }

    @Test
    fun `a body's value comes back out`() = runBlocking {
        assertEquals(42, AskTurnstile().withTurn { 41 + 1 })
    }

    @Test
    fun `work that would have to wait is skipped rather than queued`() = runBlocking(Dispatchers.Default) {
        val turnstile = AskTurnstile()
        val gate = Gate()

        val holder = launch { turnstile.withTurn { gate.wait() } }
        gate.waitUntilHeld()

        // A prewarm that has to wait is pointless: whatever it would load, the
        // question holding the turn has loaded already.
        val ran = async { turnstile.ifFree { trace.add("prewarmed") } }.await()
        assertFalse(ran)
        assertTrue(trace.isEmpty())

        gate.open()
        holder.join()
        assertTrue(turnstile.ifFree { trace.add("prewarmed") })
        assertEquals(listOf("prewarmed"), trace.toList())
    }
}
