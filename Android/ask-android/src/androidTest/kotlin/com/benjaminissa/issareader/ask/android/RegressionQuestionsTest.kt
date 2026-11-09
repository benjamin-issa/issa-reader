package com.benjaminissa.issareader.ask.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.benjaminissa.issareader.ask.AskAnswer
import com.benjaminissa.issareader.ask.AskEngine
import com.benjaminissa.issareader.ask.AskEvent
import com.benjaminissa.issareader.ask.AskIndexStore
import com.benjaminissa.issareader.ask.AskPhase
import com.benjaminissa.issareader.ask.BookSource
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.Serializable
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Every fixture question, asked of Gemini Nano on a device that has it —
 * IssaAsk's `RegressionQuestionsTests`.
 *
 * The deterministic suites prove the retrieval is right. This proves the only
 * thing they cannot: that the sentences retrieval chose are enough for the
 * on-device model to answer from, and that the ones it must not see are not
 * there. Both books, because the second defect it guards ("What happened to
 * the author's son?" answered from a paragraph about Dr Mandeville) is only
 * visible on the second one.
 */
@RunWith(AndroidJUnit4::class)
class RegressionQuestionsTest {
    @Test
    fun everyFixtureQuestionIsAnsweredFromWhatTheReaderHasRead() = runBlocking {
        Device.requireModel()
        for ((book, questions) in QuestionFixture.books()) {
            val run = RegressionRun.start(book)
            try {
                for (fixture in QuestionFixture.all(questions)) {
                    val outcome = run.ask(fixture)
                    outcome.printSummary()
                    outcome.assert()
                }
            } finally {
                run.tearDown()
            }
        }
    }
}

/**
 * One book, indexed once, asked any number of questions. Shared between the
 * regression suite, which asserts, and the scorecard, which records — so the
 * two can never drift into measuring different things.
 */
internal class RegressionRun private constructor(
    val book: DeviceBook,
    val directory: File,
    val store: AskIndexStore,
    val source: BookSource,
    val model: GeminiNanoAnswerModel,
) {
    fun tearDown() = Device.remove(directory)

    /** What one question came back with, and every fact the assertions and the scorecard read off it. */
    @Serializable
    data class Outcome(
        val book: String,
        val name: String,
        val question: String,
        val spine: Int,
        val milliseconds: Long,
        val answer: String,
        val citations: List<Int>,
        val notYetRevealed: Boolean,
        val modelCalled: Boolean,
        /** Null when the fixture has no expectation; the sentinel is not a pass. */
        val containsExpected: Boolean?,
        val leaked: List<String>,
        /** Names the answer introduced that the read part of the book had not. */
        val newNames: List<String>,
        val answerWords: Int,
        val expectedNotYet: Boolean?,
        val expectedModelCalled: Boolean,
        val allowsNewNames: Boolean,
        val modelDescription: String,
        val contextSize: Int,
    ) {
        fun printSummary() {
            println(
                "[ask] $book — $name — spine $spine, $milliseconds ms\n[ask] Q: $question\n[ask] A: $answer\n" +
                    "[ask] citations $citations, notYetRevealed $notYetRevealed, newNames $newNames",
            )
        }

        /**
         * Every check this suite makes, in one list, which [assert] and the
         * scorecard's tally both read.
         */
        val checks: List<Pair<Boolean, String>>
            get() = listOf(
                (expectedNotYet?.let { it == notYetRevealed } ?: true) to "$name: notYetRevealed $notYetRevealed",
                (modelCalled == expectedModelCalled) to "$name: modelCalled $modelCalled",
                (containsExpected ?: true) to "$name: $answer",
                leaked.isEmpty() to "$name: leaked $leaked",
                // A name the question did not ask about and the book has not
                // introduced is the one thing this feature promised not to do.
                newNames.isEmpty() to "$name: $newNames",
            )

        fun assert() {
            for ((passed, detail) in checks) assertTrue(detail, passed)
        }

        val passes: Boolean get() = checks.all { it.first }
    }

    suspend fun ask(fixture: QuestionFixture): Outcome {
        val boundary = book.endOf(fixture.spine)
        val start = System.nanoTime()
        var answer: AskAnswer? = null
        val phases = ArrayList<AskPhase>()
        // The engine the app answers with, built the way the app builds it.
        val engine = AskEngine.forQuestion(model, store, book.bookUuid, boundary)
        engine.ask(fixture.question, source, boundary).collect { event ->
            when (event) {
                is AskEvent.Answered -> answer = event.answer
                is AskEvent.Phase -> phases.add(event.phase)
                is AskEvent.Partial -> Unit
            }
        }
        val milliseconds = Device.elapsedMilliseconds(start)
        val found = answer
        assertNotNull(fixture.name, found)
        found!!
        val lowered = found.text.lowercase()

        // Asserted through the index, which is the guard the engine applies;
        // only where a fixture forbids new names.
        val newNames = if (!fixture.allowsNewNames && !found.notYetRevealed) {
            store.unmetWords(AskEngine.unvettedNames(found.text), book.bookUuid, boundary).sorted()
        } else {
            emptyList()
        }

        return Outcome(
            book = book.resource,
            name = fixture.name,
            question = fixture.question,
            spine = fixture.spine,
            milliseconds = milliseconds,
            answer = found.text,
            citations = found.citations,
            notYetRevealed = found.notYetRevealed,
            // `Thinking` is yielded only when the model is about to be asked.
            modelCalled = AskPhase.Thinking in phases,
            containsExpected = fixture.containsExpected(found),
            leaked = fixture.answerExcludes.filter { lowered.contains(it) },
            newNames = newNames,
            answerWords = found.text.split(Regex("\\s+")).count { it.isNotEmpty() },
            expectedNotYet = fixture.notYet,
            expectedModelCalled = fixture.modelCalled,
            allowsNewNames = fixture.allowsNewNames,
            modelDescription = model.modelDescription,
            contextSize = model.contextSize,
        )
    }

    companion object {
        suspend fun start(book: DeviceBook): RegressionRun {
            val (store, source, directory) = book.preparedStore()
            return RegressionRun(book, directory, store, source, GeminiNanoAnswerModel.create())
        }
    }
}
