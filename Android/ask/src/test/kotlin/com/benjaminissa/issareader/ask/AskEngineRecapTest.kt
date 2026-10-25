package com.benjaminissa.issareader.ask

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** The two engine-level paths that must not reach the model at all, and the one that must. */
class AskEngineRecapTest {
    /**
     * A reader who opens the sheet before reading a word. "What has happened so
     * far?" is the first chip on the sheet, so the question is one tap away
     * from a boundary with nothing behind it.
     */
    @Test
    fun `a recap with nothing behind it never reaches the model`() = runBlocking {
        val (store, source, directory) = AskFixture.preparedStore()
        try {
            // Before the first indexed passage of the first spine.
            val boundary = ReadingBoundary(spineIndex = 0, charOffset = 0)
            val retrieval = AskRetriever(store, AskFixture.bookUuid, boundary).retrieve(AskSuggestions.recap)
            if (retrieval is AskRetriever.Retrieval.NotYet) {
                // A recap names nobody, so there is nothing to report as unmet.
                assertTrue(retrieval.unmet.isEmpty())
            } else {
                fail("a recap over no passages should be not-yet")
            }

            val model = ScriptedAnswerModel()
            val engine = AskEngine(model, store)
            val (events, failure) = drain(engine.ask(AskSuggestions.recap, source, boundary))
            assertNull(failure)
            // What it costs is the model call, so that is what is asserted.
            assertTrue(model.received.isEmpty())
            assertFalse(thinking in events)
            val answer = answer(events)!!
            assertTrue(answer.notYetRevealed)
            assertEquals(AskAnswer.Origin.WITHHELD, answer.origin)
            assertTrue(answer.sources.isEmpty())
        } finally {
            AskFixture.remove(directory)
        }
    }

    /**
     * "wait is Dask Ryn's brother?" asks whether, and the deterministic table
     * may only answer a question that asks who.
     */
    @Test
    fun `a yes or no kinship question behind a filler is read by the model, not the table`() = runBlocking {
        val (store, source, boundary, directory) = AskFixture.syntheticStore(listOf(AskEngineTest.kinshipChapter))
        try {
            val model = ScriptedAnswerModel()
            val engine = AskEngine(model, store)
            val (events, failure) = drain(engine.ask("wait is Dask Ryn's brother?", source, boundary))
            assertNull(failure)
            assertEquals(1, model.received.size)
            assertTrue(thinking in events)
            // What matters is that the book did not claim to have said it.
            assertNotEquals(AskAnswer.Origin.BOOK, answer(events)!!.origin)
        } finally {
            AskFixture.remove(directory)
        }
    }
}

/** The kinship fast path, against the context the retriever adds behind it. */
class AskEngineKinshipTopUpTest {
    @Test
    fun `a sentence before the antecedent does not cost the book its own answer`() = runBlocking {
        // One ordinary sentence ahead of the antecedent breaks the tie that let
        // the kin sentence's window and its paragraph start at the same offset.
        val chapter = AskEngineTest.kinshipChapter.toMutableList()
        chapter[0] = "The rain had not stopped for a week. " + chapter[0]
        val (store, source, boundary, directory) = AskFixture.syntheticStore(listOf(chapter))
        try {
            val model = ScriptedAnswerModel()
            val engine = AskEngine(model, store)
            val (events, failure) = drain(engine.ask("What is the name of Ryn's brother?", source, boundary))
            assertNull(failure)
            val answer = answer(events)!!
            assertEquals("Ryn's brother is Dask.", answer.text)
            // Nothing composed it, and nothing was asked to.
            assertEquals(AskAnswer.Origin.BOOK, answer.origin)
            assertTrue(model.received.isEmpty())
            assertFalse(thinking in events)
        } finally {
            AskFixture.remove(directory)
        }
    }
}
