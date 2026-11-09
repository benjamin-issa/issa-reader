package com.benjaminissa.issareader.app.ask

import com.benjaminissa.issareader.app.ask.AskHarness.Companion.boundary
import com.benjaminissa.issareader.app.ask.AskHarness.Companion.source
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ask.AskIndexStore
import com.benjaminissa.issareader.ask.ScriptedAnswerModel
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.core.KeyValueStore
import kotlinx.coroutines.delay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The job model, driven by a model whose answers are a function of nothing.
 * Swift's `AskCoordinatorTests`.
 *
 * What is asserted here is the part that is genuinely hard to see by hand: a
 * job has to outlive the sheet that started it, because a first question about
 * a long book on a phone takes half a minute and the reader is expected to
 * close the sheet and carry on reading. Everything else in this file exists so
 * that property cannot be broken quietly by a later tidy-up.
 */
class AskCoordinatorTest {
    private suspend fun settle(job: AskJob) {
        job.task?.join()
    }

    private fun assertAnswered(job: AskJob) {
        assertTrue("expected an answer, got ${job.state}", job.state.isAnswered)
    }

    // The job outlives the sheet

    @Test
    fun `closing the sheet does not stop the answer`() = AskHarness().use { harness ->
        harness.run {
            val source = source()
            val job = assertNotNull(coordinator.ask("What did Alice follow?", source, boundary()))
            coordinator.sheetDismissed(source.bookUuid)
            assertTrue("the job has to know it was left running", job.owesNotification)
            assertSame("and it has to still be there", job, coordinator.job(source.bookUuid))

            settle(job)
            assertAnswered(job)
            assertSame("the answer is what the reader comes back to", job, coordinator.job(source.bookUuid))
        }
    }

    /**
     * The other half: a sheet closed on a *finished* answer keeps nothing. An
     * answer nobody is looking at exists only to be read.
     */
    @Test
    fun `closing the sheet on a finished answer clears it`() = AskHarness().use { harness ->
        harness.run {
            val source = source()
            val job = assertNotNull(coordinator.ask("What did Alice follow?", source, boundary()))
            settle(job)
            assertAnswered(job)

            coordinator.sheetDismissed(source.bookUuid)
            assertNull(coordinator.job(source.bookUuid))
        }
    }

    @Test
    fun `discard empties the coordinator`() = AskHarness().use { harness ->
        harness.run {
            val source = source()
            val job = assertNotNull(coordinator.ask("What did Alice follow?", source, boundary()))
            coordinator.discard(source.bookUuid)
            assertNull(coordinator.job(source.bookUuid))
            assertTrue(coordinator.jobs.isEmpty())
            // The pipeline goes with it: a job nothing is showing must not be
            // left running against the on-device model, which answers one at a time.
            settle(job)
            assertTrue(job.task?.isCancelled == true)
        }
    }

    // One job per book

    @Test
    fun `a second question about the same book replaces the first`() = AskHarness().use { harness ->
        harness.run {
            val source = source()
            val first = assertNotNull(coordinator.ask("What did Alice follow?", source, boundary()))
            val second = assertNotNull(coordinator.ask("Who is Alice?", source, boundary()))
            assertEquals(1, coordinator.jobs.size)
            assertSame(second, coordinator.job(source.bookUuid))
            assertNotSame(first, second)
            settle(second)
        }
    }

    /** Two books' answers must not overwrite each other. */
    @Test
    fun `two books each keep their own job`() = AskHarness().use { harness ->
        harness.run {
            val first = assertNotNull(coordinator.ask("What did Alice follow?", source("alice-uuid"), boundary()))
            val second = assertNotNull(coordinator.ask("What did Alice follow?", source("other-uuid"), boundary()))
            assertEquals(2, coordinator.jobs.size)
            settle(first)
            settle(second)
        }
    }

    /**
     * The only test that catches the coordinator forgetting to share its
     * turnstile: a fresh engine is built per question, so two books were two
     * engines, two turnstiles and two concurrent generations.
     */
    @Test
    fun `two books asked at once are answered one after the other`() = AskHarness(
        turns = listOf(
            ScriptedAnswerModel.Turn(partials = listOf("first"), holdsAfterPartials = 1),
            ScriptedAnswerModel.Turn.answer("The other book's answer.\nSources: 1"),
        ),
    ).use { harness ->
        harness.run {
            val first = assertNotNull(coordinator.ask("What did Alice follow?", source("alice-uuid"), boundary()))
            model.waitUntilHolding()
            val second = assertNotNull(coordinator.ask("Who is Alice?", source("other-uuid"), boundary()))
            delay(50)
            assertEquals("the second book's question must be waiting", 1, model.received.size)

            model.release()
            settle(first)
            settle(second)
            assertEquals(2, model.received.size)
            assertEquals(1, model.peakConcurrency)
        }
    }

    // Citations

    /** The whole apparatus, end to end, in the place the sheet reads it from. */
    @Test
    fun `an answered job carries the excerpts it rests on, inside the captured boundary`() = AskHarness(
        turns = listOf(ScriptedAnswerModel.Turn.answer("Alice followed a white rabbit down a hole.\nSources: 1, 2")),
    ).use { harness ->
        harness.run {
            val boundary = boundary()
            val job = assertNotNull(coordinator.ask("What did Alice follow?", source(), boundary))
            settle(job)
            val answered = job.state as? AskJob.State.Answered ?: error("expected an answer, got ${job.state}")
            assertEquals(listOf(1, 2), answered.answer.sources.map { it.ordinal })
            for (cited in answered.answer.sources) {
                // Bounded by the reader's own position by construction.
                assertTrue(cited.passage.spineIndex <= boundary.spineIndex)
                assertTrue(cited.passage.displayText.isNotEmpty())
            }
        }
    }

    // Leaving the app mid-question

    /** The reader's own Cancel must still take the job with it. */
    @Test
    fun `a question the reader cancelled still goes`() = AskHarness(
        turns = listOf(ScriptedAnswerModel.Turn(partials = listOf("Alice"), holdsAfterPartials = 1)),
    ).use { harness ->
        harness.run {
            val source = source()
            val job = assertNotNull(coordinator.ask("What did Alice follow?", source, boundary()))
            model.waitUntilHolding()
            coordinator.cancel(source.bookUuid)
            settle(job)

            assertNull(coordinator.job(source.bookUuid))
            assertFalse(job.isHeld)
        }
    }

    /**
     * Backgrounding with the sheet open used to be a path that could never
     * notify: the promise was made only by closing the sheet.
     */
    @Test
    fun `leaving the app mid-question owes the reader a notification`() = AskHarness(
        turns = listOf(ScriptedAnswerModel.Turn(partials = listOf("Alice"), holdsAfterPartials = 1)),
    ).use { harness ->
        harness.run {
            val job = assertNotNull(coordinator.ask("What did Alice follow?", source(), boundary()))
            model.waitUntilHolding()
            assertFalse("nothing has been promised yet", job.owesNotification)

            coordinator.appDidEnterBackground()
            assertTrue("the reader who leaves mid-question is who it is for", job.owesNotification)

            model.release()
            settle(job)
            coordinator.appDidBecomeActive()
        }
    }

    /** An answer finishing just as the app goes away is still posted — once, by the notifier. */
    @Test
    fun `an answer that finishes in the background is announced`() {
        val notifier = CountingNotifier()
        AskHarness(
            turns = listOf(ScriptedAnswerModel.Turn(partials = listOf("Alice followed a rabbit.\nSources: 1"), holdsAfterPartials = 1)),
            notifier = notifier,
        ).use { harness ->
            harness.run {
                val job = assertNotNull(coordinator.ask("What did Alice follow?", source(), boundary()))
                model.waitUntilHolding()
                coordinator.appDidEnterBackground()
                model.release()
                settle(job)
                assertAnswered(job)
                assertEquals(1, notifier.posted)
            }
        }
    }

    // Android: Gemini Nano answers only in the foreground

    /**
     * The promise `AskFailure.BackgroundBlocked` makes — "Your question will be
     * answered when you come back" — kept: AICore refuses a generation for an
     * app that is not on screen, so the question is held, and asked again,
     * with the boundary it was first asked with, when the app returns.
     */
    @Test
    fun `a question Gemini Nano refused in the background is asked again on return`() {
        val notifier = CountingNotifier()
        AskHarness(
            turns = listOf(
                ScriptedAnswerModel.Turn(failure = AskFailure.BackgroundBlocked),
                ScriptedAnswerModel.Turn.answer("Alice followed a white rabbit.\nSources: 1"),
            ),
            notifier = notifier,
        ).use { harness ->
            harness.run {
                val source = source()
                val boundary = boundary()
                val held = assertNotNull(coordinator.ask("What did Alice follow?", source, boundary))
                // Before the job has run a step: the reader left as they asked.
                coordinator.appDidEnterBackground()
                settle(held)

                assertSame("the question is kept, not dropped", held, coordinator.job(source.bookUuid))
                assertTrue(held.isHeld)
                assertEquals(AskJob.State.Failed(AskFailure.BackgroundBlocked), held.state)
                assertTrue("a held question is still pending", held.isPending)
                assertEquals("the reader who left is told it can be answered", 1, notifier.readyToAnswer)
                // A closed sheet does not throw a held question away.
                coordinator.sheetDismissed(source.bookUuid)
                assertSame(held, coordinator.job(source.bookUuid))

                coordinator.appDidBecomeActive()
                val resumed = assertNotNull(coordinator.job(source.bookUuid))
                assertNotSame(held, resumed)
                assertEquals(held.question, resumed.question)
                assertEquals("bounded where the reader was when they asked", boundary, resumed.boundary)
                settle(resumed)
                assertAnswered(resumed)
                assertFalse(resumed.isHeld)
                assertEquals(2, model.received.size)
                assertTrue("the banner that stood in for it is taken back", source.bookUuid in notifier.removed)
            }
        }
    }

    /** A refusal that lands after the app is back is answered now, rather than at the next return. */
    @Test
    fun `a refusal that lands with the app in front is asked again at once`() = AskHarness(
        turns = listOf(
            ScriptedAnswerModel.Turn(failure = AskFailure.BackgroundBlocked),
            ScriptedAnswerModel.Turn.answer("Alice followed a white rabbit.\nSources: 1"),
        ),
    ).use { harness ->
        harness.run {
            val source = source()
            val first = assertNotNull(coordinator.ask("What did Alice follow?", source, boundary()))
            settle(first)
            val resumed = assertNotNull(coordinator.job(source.bookUuid))
            assertNotSame(first, resumed)
            settle(resumed)
            assertAnswered(resumed)
        }
    }

    /** And never twice in a row: a re-asked question refused again waits for the next return, so the two cannot chase each other. */
    @Test
    fun `a re-asked question refused again waits for the next return`() = AskHarness(
        turns = listOf(
            ScriptedAnswerModel.Turn(failure = AskFailure.BackgroundBlocked),
            ScriptedAnswerModel.Turn(failure = AskFailure.BackgroundBlocked),
            ScriptedAnswerModel.Turn.answer("Alice followed a white rabbit.\nSources: 1"),
        ),
    ).use { harness ->
        harness.run {
            val source = source()
            val first = assertNotNull(coordinator.ask("What did Alice follow?", source, boundary()))
            settle(first)
            val second = assertNotNull(coordinator.job(source.bookUuid))
            settle(second)
            assertTrue(second.isHeld)
            assertSame(second, coordinator.job(source.bookUuid))
            assertEquals(2, model.received.size)

            coordinator.appDidBecomeActive()
            val third = assertNotNull(coordinator.job(source.bookUuid))
            settle(third)
            assertAnswered(third)
            assertEquals(3, model.received.size)
        }
    }

    // Being asked about notifications

    /**
     * Once, ever, and in context: the first question is the moment the reader
     * has something to be told about later. (The iPhone asks when a sheet is
     * closed on a working question; the reader moved it here.)
     */
    @Test
    fun `the notification prompt is offered once and remembered`() = AskHarness().use { harness ->
        harness.run {
            assertFalse(defaults.getBoolean(AskCoordinator.ASKED_FOR_NOTIFICATIONS_KEY))
            val job = assertNotNull(coordinator.ask("What did Alice follow?", source(), boundary()))
            assertTrue(defaults.getBoolean(AskCoordinator.ASKED_FOR_NOTIFICATIONS_KEY))
            settle(job)
        }
    }

    /**
     * Once means once across questions, not one flag set: with the once-only
     * guard deleted, every question asked again and the test above stayed green.
     */
    @Test
    fun `two questions ask about notifications once`() {
        val notifier = CountingNotifier()
        AskHarness(notifier = notifier).use { harness ->
            harness.run {
                val first = assertNotNull(coordinator.ask("What did Alice follow?", source(), boundary()))
                settle(first)
                val second = assertNotNull(coordinator.ask("Who is Alice?", source(), boundary()))
                coordinator.sheetDismissed(source().bookUuid)
                settle(second)
                assertEquals(1, notifier.authorizationRequests)
            }
        }
    }

    // Getting ready

    /** A warm-up that failed was remembered as done, so no later opening of the sheet tried again. */
    @Test
    fun `a warm-up that failed is tried again the next time the sheet opens`() {
        // A file where the index directory should be: the build cannot create
        // it, so the first warm-up fails.
        val blocked = File(AskHarness.temporaryDirectory(), "blocked")
        blocked.writeText("not a directory")
        val store = AskIndexStore(blocked)
        AskHarness(store = store, directory = blocked.parentFile).use { harness ->
            harness.run {
                val source = source()
                coordinator.prepare(source)
                coordinator.warmUp(source.bookUuid)?.join()
                assertFalse(store.isPrepared(source))

                // Whatever was in the way is gone; the next opening warms up for real.
                assertTrue(blocked.delete())
                coordinator.prepare(source)
                val retry = coordinator.warmUp(source.bookUuid)
                assertNotNull("the failed warm-up must not count as done", retry)
                retry?.join()
                assertTrue(store.isPrepared(source))
            }
        }
    }

    // The setting

    @Test
    fun `the Ask switch is off until it is turned on, and survives a relaunch`() {
        val defaults = RecordingStore()
        val settings = PlaybackSettings(defaults)
        assertFalse("a feature nobody has asked for is off", settings.askEnabled)
        assertFalse("and writes nothing until it is touched", PlaybackSettings.ASK_ENABLED_KEY in defaults.written)

        settings.askEnabled = true
        assertTrue(defaults.getBoolean(PlaybackSettings.ASK_ENABLED_KEY))
        // A fresh instance is what the next launch builds.
        assertTrue(PlaybackSettings(defaults).askEnabled)

        settings.askEnabled = false
        assertFalse(PlaybackSettings(defaults).askEnabled)
    }

    /** Every key written, so "writes nothing" is a fact rather than a default read back. */
    private class RecordingStore(private val inner: KeyValueStore = InMemoryKeyValueStore()) : KeyValueStore by inner {
        val written = mutableSetOf<String>()

        override fun putBoolean(key: String, value: Boolean) {
            written += key
            inner.putBoolean(key, value)
        }

        override fun putString(key: String, value: String?) {
            written += key
            inner.putString(key, value)
        }
    }
}

/** JUnit's `assertNotNull`, returning the value it checked. */
internal fun <T : Any> assertNotNull(value: T?): T = assertNotNull(null, value)

internal fun <T : Any> assertNotNull(message: String?, value: T?): T {
    org.junit.Assert.assertNotNull(message, value)
    return value!!
}
