package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.render.TextRange
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The one tokeniser, which is the reason the extractor's comparisons mean
 * anything: `KinshipExtractor` asks whether a word of the book's sentence is
 * one of the question's subject tokens.
 */
class WordsTest {
    @Test
    fun `a question and a sentence tokenise a name the same way`() {
        for (name in listOf("Jean'Luc", "Jean-Luc", "O'Brien", "St.John", "Ryn")) {
            val asked = QuestionReader.words("Who is $name?")
            val printed = Words.split("She met $name at the gate.")
            val questionToken = asked.lastOrNull()?.token
            val sentenceToken = printed.drop(2).firstOrNull()?.token
            assertEquals("$name: $questionToken against $sentenceToken", questionToken, sentenceToken)
        }
    }

    @Test
    fun `a possessive is stripped the same way on both sides`() {
        val asked = QuestionReader.words("Who is Ryn's brother?").drop(2).firstOrNull()
        val printed = Words.split("Her brother, Ryn's, arrived.").drop(2).firstOrNull()
        assertEquals(true, asked?.isPossessive)
        assertEquals("ryn", asked?.token)
        assertEquals("ryn", printed?.token)
    }

    @Test
    fun `who's still becomes two words, so the identity lead-in matches`() {
        assertEquals(listOf("who", "is", "ryn"), QuestionReader.words("Who's Ryn?").map { it.token })
    }
}

/**
 * The one place the app answers without asking the model.
 *
 * Every test here is about the extractor declining. Over-reach is a confident
 * wrong answer with a citation on it; under-reach is the model answering with
 * the right sentence still in front of it.
 */
class KinshipExtractorTest {
    private val ryn = Subject(display = "Ryn", tokens = listOf("ryn"), isKnownName = true)
    private val brother = KinRelation.matching("brother")

    /** One sentence, as `EvidenceFinder` would have handed it over. */
    private fun evidence(sentence: String, preceding: String? = null): Evidence = Evidence(
        excerpt = Passage(
            spineIndex = 4, ordinal = 1, start = 0, end = sentence.length,
            words = PassageChunker.wordCount(sentence), text = sentence,
        ),
        sentence = TextRange(0, sentence.length),
        role = Evidence.Role.KINSHIP,
        sentenceText = sentence,
        precedingText = preceding,
    )

    private fun names(sentence: String, preceding: String? = null, known: Set<String> = setOf("ryn", "dask")): List<String> =
        KinshipExtractor.names(ryn, brother, listOf(evidence(sentence, preceding)), knownNames = known).map { it.name }

    // The six shapes

    @Test
    fun `the table reads the six ways a book states a relationship`() {
        // X's KIN, NAME
        assertEquals(listOf("Dask"), names("Ryn's brother, Dask, had trained her."))
        // NAME, X's KIN
        assertEquals(listOf("Dask"), names("Dask, Ryn's brother, had trained her."))
        // NAME was X's KIN
        assertEquals(listOf("Dask"), names("Dask was Ryn's brother, and he trained her."))
        // X's KIN was called NAME
        assertEquals(listOf("Dask"), names("Ryn's brother was called Dask."))
        // PRON KIN, NAME
        assertEquals(listOf("Dask"), names("Ryn remembered. Her brother, Dask, had trained her."))
        // NAME, PRON KIN
        assertEquals(listOf("Dask"), names("Ryn waited while Dask, her brother, watched the door."))
    }

    @Test
    fun `an adjective between the owner and the relation changes nothing`() {
        assertEquals(listOf("Dask"), names("Ryn's younger brother, Dask, had trained her."))
        assertEquals(listOf("Dask"), names("Ryn's own elder brother, Dask, waited."))
    }

    // Reach

    @Test
    fun `a pronoun reaches back exactly one sentence, and only when nobody else is there`() {
        // The sentence names her: nothing to resolve.
        assertEquals(listOf("Dask"), names("Ryn sighed, and her brother, Dask, said nothing."))
        // One sentence back, and she is the only person in it.
        assertEquals(listOf("Dask"), names("Her brother, Dask, had trained her.", preceding = "Ryn had grown up on the streets."))
        // One sentence back, but somebody else is standing in it: "her" is as
        // likely to be Aldric's sister as Ryn.
        assertTrue(names("Her brother, Dask, had trained her.", preceding = "Ryn turned away, and Aldric watched her go.").isEmpty())
        // Nothing to reach back to at all.
        assertTrue(names("Her brother, Dask, had trained her.").isEmpty())
    }

    @Test
    fun `a relationship somebody else owns is not the subject's`() {
        assertTrue(names("Marek's brother, Dask, had gone north.").isEmpty())
    }

    // Declining

    @Test
    fun `a negation drops the match rather than reversing it`() {
        assertTrue(names("Dask was not Ryn's brother, whatever she said.").isEmpty())
        assertTrue(names("Ryn's brother, Dask, was never mentioned again.").isEmpty())
    }

    @Test
    fun `two names is the model's problem, not the table's`() {
        val evidence = listOf(evidence("Ryn's brother, Dask, had trained her."), evidence("Ryn's brother, Aldric, disagreed."))
        val known = setOf("ryn", "dask", "aldric")
        val matches = KinshipExtractor.names(ryn, brother, evidence, knownNames = known)
        assertEquals(listOf("Dask", "Aldric"), matches.map { it.name })
        // Two brothers, or a pattern that matched something it should not have.
        assertNull(KinshipExtractor.answer(ryn, brother, QuestionKind.KinshipForm.WHO_IS, evidence, knownNames = known))
    }

    @Test
    fun `an unnamed relative produces no name at all`() {
        // Alice's sister is never named in the whole book, and this is the
        // shape of the sentence that mentions her.
        val alice = Subject(display = "Alice", tokens = listOf("alice"), isKnownName = true)
        val matches = KinshipExtractor.names(
            alice, KinRelation.matching("sister"),
            listOf(evidence("Alice was tired of sitting by her sister on the bank.")),
            knownNames = setOf("alice"),
        )
        assertTrue(matches.isEmpty())
    }

    @Test
    fun `a capital that only opens a sentence is not a name`() {
        // "Nobody was Ryn's brother" is not an answer.
        assertTrue(names("Nobody was Ryn's brother.", known = setOf("ryn")).isEmpty())
        // …unless the book has actually used it as one.
        assertEquals(listOf("Dask"), names("Dask was Ryn's brother.", known = setOf("ryn", "dask")))
    }

    @Test
    fun `an honorific is not part of the answer`() {
        assertEquals(listOf("Dask"), names("Ryn's brother, Mr. Dask, had trained her."))
    }

    // How far the finder reaches

    @Test
    fun `a second name stated late is still read, and still declines`() {
        // Twelve kin sentences, not eight: the ninth to the twelfth is exactly
        // where a book names a *second* brother.
        val sentences = listOf("Ryn's brother, Dask, had trained her.") +
            List(10) { "Ryn glanced at her brother and said nothing." } +
            listOf("Ryn's brother, Marek, had come back that winter.")
        val text = sentences.joinToString(" ")
        val passage = RetrievedPassage(
            Passage(spineIndex = 4, ordinal = 0, start = 0, end = text.length, words = PassageChunker.wordCount(text), text = text),
            bm25 = -1.0, isTruncated = false,
        )
        val evidence = EvidenceFinder.kinship(ryn, brother, listOf(passage))
        // Written against the constant rather than against twelve.
        assertEquals(EvidenceFinder.Limits.kinshipSentences, evidence.size)

        val known = setOf("ryn", "dask", "marek")
        val matches = KinshipExtractor.names(ryn, brother, evidence, knownNames = known)
        assertEquals(listOf("Dask", "Marek"), matches.map { it.name })
        assertEquals(listOf(0, 11), matches.map { it.evidenceIndex })
        assertNull(KinshipExtractor.answer(ryn, brother, QuestionKind.KinshipForm.WHO_IS, evidence, knownNames = known))
    }

    // The answer

    @Test
    fun `one name is answered outright, with a citation`() {
        val answer = KinshipExtractor.answer(
            ryn, brother, QuestionKind.KinshipForm.WHO_IS,
            listOf(evidence("The mists came early."), evidence("Ryn's brother, Dask, had trained her.")),
            knownNames = setOf("ryn", "dask"),
        )!!
        assertEquals("Ryn's brother is Dask.", answer.text)
        // One-based, the way the prompt numbers its excerpts.
        assertEquals(listOf(2), answer.citations)
        assertTrue(!answer.notYetRevealed)
    }

    @Test
    fun `only a who-is question is answered without the model`() {
        val evidence = listOf(evidence("Ryn's brother, Dask, had trained her."))
        for (form in listOf(QuestionKind.KinshipForm.YES_NO, QuestionKind.KinshipForm.HOW_RELATED)) {
            assertNull(form.name, KinshipExtractor.answer(ryn, brother, form, evidence, knownNames = setOf("ryn", "dask")))
        }
        assertNull(KinshipExtractor.answer(ryn, null, QuestionKind.KinshipForm.WHO_IS, evidence, knownNames = setOf("ryn", "dask")))
    }
}
