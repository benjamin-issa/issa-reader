package com.benjaminissa.issareader.ask

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The holes between the two spoiler guards, from the 1.4.0 final review.
 *
 * The answer-side vetting exempted every word of the question on the premise
 * that the question side had ruled on it. The question side never probed a
 * recap-shaped question, a question's second sentence, or a name typed in
 * lower case — so in each of those positions an unmet name passed both guards
 * (R-04). Every case is at the end of *Alice* Chapter I, where the Cheshire
 * Cat, the Queen and the Duchess are all still ahead.
 *
 * And the other direction (R-15): a question that opens with a contraction or
 * with the classifier's own filler made that word a name, found it unmet, and
 * refused a question about characters the reader had met.
 */
class SpoilerGateTest {
    private data class Asked(val answer: AskAnswer, val partials: List<String>, val modelCalled: Boolean)

    /** Asks one question with a scripted answer, and reports what the reader would have been shown. */
    private suspend fun ask(question: String, scripted: String, spine: Int = AskFixture.Spine.chapterI): Asked {
        val (store, source, directory) = AskFixture.preparedStore()
        try {
            val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn.answer(scripted)))
            val engine = AskEngine(model, store)
            val (events, failure) = drain(engine.ask(question, source, AskFixture.endOf(spine)))
            assertNull(failure)
            return Asked(answer(events)!!, partials(events), model.received.isNotEmpty())
        } finally {
            AskFixture.remove(directory)
        }
    }

    // R-04: the question side probes what the answer side used to exempt

    @Test
    fun `an unmet name is refused wherever the question puts it`() = runBlocking {
        for ((question, scripted) in listOf(
            // (a) A recap pattern inside a question about somebody.
            "What has happened to the Cheshire Cat?" to "The Cheshire Cat grins at Alice from a tree and then vanishes.\nSources: 1",
            "Summarize the Cheshire Cat's role so far." to "The Cheshire Cat grins at Alice and gives her directions.\nSources: 1",
            // (b) The second sentence of a two-sentence question.
            "Who is Alice? Does she ever meet the Cheshire Cat?" to "Yes, she later meets the Cheshire Cat.\nSources: 1",
            // The same with a name only the capital in the second sentence can
            // catch.
            "Who is Alice? Does she ever meet the Duchess?" to "Yes, she later meets the Duchess and the Cheshire Cat.\nSources: 1",
            // (c) A name typed in lower case: no capital, no candidate.
            "who is the cheshire cat?" to "The Cheshire Cat is a grinning cat who can vanish.\nSources: 1",
        )) {
            val (answer, partials, modelCalled) = ask(question, scripted)
            assertTrue("$question was answered: ${answer.text}", answer.notYetRevealed)
            assertEquals(question, AskAnswer.Origin.WITHHELD, answer.origin)
            assertFalse(question, answer.text.contains("Cheshire"))
            assertFalse(question, partials.any { it.contains("Cheshire") })
            // The question side decided, so the model never had the chance.
            assertFalse("$question reached the model", modelCalled)
        }
    }

    /** "queen" and "hearts" typed in lower case: the answer side must not exempt the question's words. */
    @Test
    fun `an answer naming an unmet character is refused even when the question named it`() = runBlocking {
        val (answer, partials, _) = ask(
            "who is the queen of hearts?",
            "The Queen of Hearts is a furious ruler who orders beheadings.\nSources: 1",
        )
        assertTrue("answered: ${answer.text}", answer.notYetRevealed)
        assertFalse(answer.text.contains("Queen"))
        assertFalse(partials.any { it.contains("Queen") })
    }

    /** Without these the guards could pass everything above by refusing everything. */
    @Test
    fun `a question whose every name has been met is still answered`() = runBlocking {
        for ((question, scripted, shown) in listOf(
            Triple("What has happened so far?", "Alice followed the White Rabbit down a hole.\nSources: 1", "Rabbit"),
            Triple("Who is Alice? Does she have a cat?", "Alice is a girl whose cat is called Dinah.\nSources: 1", "Dinah"),
            Triple("who is dinah?", "Dinah is Alice's cat.\nSources: 1", "Dinah"),
            Triple("What has happened to Alice?", "Alice fell down a hole after the White Rabbit.\nSources: 1", "Alice"),
        )) {
            val (answer, _, modelCalled) = ask(question, scripted)
            assertFalse("$question was refused", answer.notYetRevealed)
            assertTrue(question, answer.text.contains(shown))
            assertTrue(question, modelCalled)
        }
    }

    // R-15: contractions and fillers are not names

    @Test
    fun `a question's contraction or filler is never a name candidate`() {
        for ((question, expected) in listOf(
            "What'd the Caterpillar tell Alice?" to listOf("alice", "caterpillar"),
            "Where'd the White Rabbit go?" to listOf("rabbit", "white"),
            "Who'd Alice meet first?" to listOf("alice"),
            "How'd Alice get so small?" to listOf("alice"),
            "Who're the Duchess and the Cook?" to listOf("cook", "duchess"),
            "Aren't the gardeners painting the roses?" to emptyList(),
            "Isn't the Rabbit late?" to listOf("rabbit"),
            "Didn't Alice drink it?" to listOf("alice"),
            "Won't Alice grow?" to listOf("alice"),
            "Hey, who is the Rabbit?" to listOf("rabbit"),
            "Hmm, who is Dinah?" to listOf("dinah"),
            "Sorry, Who is Dinah?" to listOf("dinah"),
            "Okay so What did Alice drink?" to listOf("alice"),
        )) {
            assertEquals(question, expected, QueryTerms.extract(question).nameCandidates)
        }
    }

    @Test
    fun `a question opening with a contraction or a filler reaches the model`() = runBlocking {
        for (question in listOf("Where'd the White Rabbit go?", "Hmm, who is Dinah?", "Hey, who is the Rabbit?", "What'd Alice drink?")) {
            val (answer, _, modelCalled) = ask(question, "Alice saw the Rabbit hurry off, and thought of Dinah.\nSources: 1")
            assertTrue("$question was refused without the model", modelCalled)
            assertFalse(question, answer.notYetRevealed)
        }
    }

    // R-16: nothing unvetted is ever drawn

    /** Every prefix of a stream, one character at a time. */
    private fun everyPrefix(text: String): List<String> = (1..text.graphemeCount()).map { text.graphemePrefix(it) }

    /** The hedge, streamed: the reader once read "the Cheshire Cat" word by word before it was replaced. */
    @Test
    fun `a spoiling stream never surfaces the name in any partial`() = runBlocking {
        val (store, source, directory) = AskFixture.preparedStore()
        try {
            val spoiler = "The story hasn't revealed that yet. However, Alice is later guided by " +
                "the Cheshire Cat, who grins and vanishes.\nSources: 1, 2"
            val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn(partials = everyPrefix(spoiler))))
            val engine = AskEngine(model, store)
            val (events, failure) = drain(
                engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterI)),
            )
            assertNull(failure)
            val partials = partials(events)
            // Not even the first letters of it.
            assertFalse(partials.lastOrNull() ?: "", partials.any { it.contains("Ch") && it.contains("However") })
            assertFalse(partials.any { it.contains("Cheshire") })
            assertTrue(answer(events)!!.notYetRevealed)
        } finally {
            AskFixture.remove(directory)
        }
    }

    /** The cost the fix must not pay: a safe answer still streams. */
    @Test
    fun `a safe answer still arrives a word at a time`() = runBlocking {
        val (store, source, directory) = AskFixture.preparedStore()
        try {
            val safe = "Alice followed the White Rabbit down a large rabbit-hole under the hedge, " +
                "and she fell for a long time.\nSources: 1"
            val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn(partials = everyPrefix(safe))))
            val engine = AskEngine(model, store)
            val (events, _) = drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
            val partials = partials(events)
            val answer = answer(events)!!
            assertFalse(answer.notYetRevealed)
            // Word by word, each one extending the last, and every one a prefix
            // of the answer the reader is finally given.
            assertTrue("${partials.size} partials", partials.size >= 15)
            assertTrue(partials.all { answer.text.startsWith(it) })
            assertTrue(partials.zipWithNext().all { (earlier, later) -> later.length > earlier.length })
            assertTrue(partials.any { it.startsWith("Alice followed the White Rabbit") })
        } finally {
            AskFixture.remove(directory)
        }
    }
}
