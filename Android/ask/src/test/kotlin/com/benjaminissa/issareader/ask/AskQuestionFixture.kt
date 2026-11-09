package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The questions both regression suites are written against, read from
 * IssaAsk's own `questions-*.json`.
 *
 * One file rather than two lists, because the deterministic assertions and the
 * real-model ones are about the same questions and drifting apart is exactly
 * how a regression suite stops meaning anything. The `evidence` expectations
 * are a function of the book and are checked without a model; the `answer`
 * ones are checked only on a device with Gemini Nano, and are kept loose on
 * purpose.
 */
@Serializable
internal data class AskQuestionFixture(
    /** What the case is for, printed beside the answer. */
    val name: String,
    val question: String,
    /** The spine index the reader has finished. 2 is Chapter I, 3 Chapter II, 7 Chapter VI. */
    val spine: Int,
    /** `identity`, `kinship`, `general` or `recap`. */
    val kind: String,
    /** Lowercased substrings that must all appear across the excerpts. */
    val evidenceContains: List<String>,
    /** …and that must not appear in any of them. */
    val evidenceExcludes: List<String>,
    /**
     * At least one of these must appear in the answer. Empty means no
     * particular wording is right — the degradation cases. Never emptied to
     * make a case pass.
     */
    val answerContainsAny: List<String>,
    /** None of these may. */
    val answerExcludes: List<String>,
    /** Whether the answer must be the "not yet revealed" sentinel. Null means either is acceptable. */
    val notYet: Boolean? = null,
    /** Whether the model should have been asked at all. */
    val modelCalled: Boolean,
    /** How many names the deterministic kinship table should find. */
    val kinshipNames: Int? = null,
    /** Whether the answer may introduce a proper noun the question did not. */
    val allowsNewNames: Boolean,
) {
    /**
     * Whether the answer names one of [answerContainsAny]; null when the
     * fixture pins no wording.
     *
     * **The sentinel is a failure here, not a pass.** A fixture with an
     * expected answer is one the reader has read far enough to be told; "the
     * story hasn't revealed that yet" is the wrong answer to it.
     */
    fun containsExpected(answer: AskAnswer): Boolean? {
        if (answerContainsAny.isEmpty()) return null
        if (answer.notYetRevealed) return false
        val lowered = answer.text.lowercase()
        return answerContainsAny.any { lowered.contains(it) }
    }

    fun boundary(book: AskBook): ReadingBoundary = book.endOf(spine)

    @Serializable
    private data class File(val questions: List<AskQuestionFixture>)

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun all(resource: String = "questions-alice"): List<AskQuestionFixture> =
            json.decodeFromString(File.serializer(), Fixtures.ask("$resource.json").readText()).questions

        /** Every book with questions written for it, so a suite covers both by iterating. */
        fun books(): List<Pair<AskBook, String>> = listOf(
            AskFixture.alice to "questions-alice",
            AskFixture.franklin to "questions-franklin",
        )
    }
}

/** The regression suite's checks, without the model: what it counts as a pass has to be right first. */
class AskQuestionFixtureTest {
    private fun fixture(expecting: List<String>) = AskQuestionFixture(
        name = "test", question = "Who is the author's father?", spine = 2, kind = "general",
        evidenceContains = emptyList(), evidenceExcludes = emptyList(), answerContainsAny = expecting,
        answerExcludes = emptyList(), notYet = null, modelCalled = true, kinshipNames = null,
        allowsNewNames = true,
    )

    @Test
    fun `a refusal fails a question the reader has read far enough to be answered`() {
        val refusal = AskAnswer(
            text = AskAnswerParser.notYetSentinel, citations = emptyList(), notYetRevealed = true,
            origin = AskAnswer.Origin.WITHHELD,
        )
        assertEquals(false, fixture(listOf("josiah")).containsExpected(refusal))
        // A fixture that pins no wording is still indifferent to it.
        assertNull(fixture(emptyList()).containsExpected(refusal))
    }

    @Test
    fun `an answer is judged by its words`() {
        val named = AskAnswer(text = "His father was Josiah Franklin.", citations = listOf(1), notYetRevealed = false)
        val unnamed = AskAnswer(text = "His father was a tradesman.", citations = listOf(1), notYetRevealed = false)
        assertEquals(true, fixture(listOf("josiah")).containsExpected(named))
        assertEquals(false, fixture(listOf("josiah")).containsExpected(unnamed))
    }
}
