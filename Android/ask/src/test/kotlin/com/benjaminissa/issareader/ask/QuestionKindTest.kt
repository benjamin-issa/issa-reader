package com.benjaminissa.issareader.ask

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The table that decides which retrieval a question gets.
 *
 * It is written against the shapes readers actually type, including the two
 * that failed on the real book: "Who is Ryn?" was answered from passing
 * mentions, and "What is the name of Ryn's brother?" was answered "Sorrel".
 */
class QuestionKindTest {
    private fun kind(question: String, known: List<String> = emptyList()): QuestionKind =
        QueryTerms.extract(question, knownNames = known).kind

    private fun subject(question: String, known: List<String> = emptyList()): Subject? = kind(question, known).subject

    // Identity

    @Test
    fun `who is X, what is the X, tell me about X are identity questions`() {
        for ((question, tokens) in listOf(
            "Who is Ryn?" to listOf("ryn"),
            "Who's Ryn?" to listOf("ryn"),
            "Who is the White Rabbit?" to listOf("white", "rabbit"),
            "Who is the Duchess?" to listOf("duchess"),
            "What is the Ferrant?" to listOf("ferrant"),
            "Tell me about Dinah" to listOf("dinah"),
            "Who was the Iron Warden really?" to listOf("iron", "warden"),
        )) {
            val kind = kind(question)
            if (kind !is QuestionKind.Identity) {
                fail("$question classified as ${kind.label}")
                continue
            }
            assertEquals(question, tokens, kind.subject.tokens)
        }
    }

    @Test
    fun `a question with too much in it is a search, not a name lookup`() {
        for (question in listOf(
            "Who is the man standing by the river bank waiting?",
            "Who are the main characters so far?",
            "What is the reason she cried so much?",
        )) {
            assertEquals(question, "general", kind(question).label)
        }
    }

    @Test
    fun `a lower-case single word is still a name lookup`() {
        val kind = kind("who is ryn?")
        assertTrue(kind is QuestionKind.Identity)
        kind as QuestionKind.Identity
        assertEquals(listOf("ryn"), kind.subject.tokens)
        assertFalse(kind.subject.isKnownName)
        // …and the book's own name table says so when it can.
        val known = kind("who is ryn?", listOf("ryn"))
        assertTrue(known is QuestionKind.Identity)
        assertTrue((known as QuestionKind.Identity).subject.isKnownName)
    }

    // Kinship

    @Test
    fun `the possessive and the relation together make a kinship question`() {
        for (question in listOf(
            "What is the name of Ryn's brother?",
            "Who is Ryn's brother?",
            "Who was Ryn's younger brother?",
            "Who is the brother of Ryn?",
        )) {
            val kind = kind(question)
            if (kind !is QuestionKind.Kinship) {
                fail("$question classified as ${kind.label}")
                continue
            }
            assertEquals(question, listOf("ryn"), kind.subject.tokens)
            assertEquals(question, "brother", kind.relation?.word)
            assertNull(question, kind.other)
            assertEquals(question, QuestionKind.KinshipForm.WHO_IS, kind.form)
        }
    }

    @Test
    fun `a yes or no kinship question is not one the extractor may answer with a name`() {
        val kind = kind("Is Dask Ryn's brother?", listOf("ryn", "dask")) as? QuestionKind.Kinship
            ?: return fail("expected kinship")
        assertEquals(listOf("ryn"), kind.subject.tokens)
        assertEquals(listOf("dask"), kind.other?.tokens)
        assertEquals("brother", kind.relation?.word)
        // Answering "Ryn's brother is Dask." to a question that asked whether he
        // is would be a confident answer to a question nobody asked.
        assertEquals(QuestionKind.KinshipForm.YES_NO, kind.form)
    }

    @Test
    fun `how are X and Y related is kinship with two subjects and no relation word`() {
        val kind = kind("How are Ryn and Marek related?", listOf("ryn", "marek")) as? QuestionKind.Kinship
            ?: return fail("expected kinship")
        assertEquals(listOf("ryn"), kind.subject.tokens)
        assertEquals(listOf("marek"), kind.other?.tokens)
        assertNull(kind.relation)
        assertEquals(QuestionKind.KinshipForm.HOW_RELATED, kind.form)
    }

    @Test
    fun `a relation nobody owns falls through to a general search`() {
        assertEquals("general", kind("Who is the brother?").label)
    }

    @Test
    fun `every relation reaches its whole group`() {
        val cousin = KinRelation.matching("cousins")
        assertNotNull(cousin)
        assertEquals("cousin", cousin?.word)
        assertTrue(cousin!!.group.contains("family"))
        // Whole spellings, not prefixes: "grandmother" is not a form of "mother".
        assertEquals("grandmother", KinRelation.matching("grandmother")?.word)
        assertNull(KinRelation.matching("rabbit"))
        assertTrue("brothers" in KinRelation.allForms)
    }

    // General

    @Test
    fun `a possessive that owns something other than a relative keeps its subject`() {
        val kind = kind("What is Alice's cat called?") as? QuestionKind.General ?: return fail("expected general")
        assertEquals(listOf("alice"), kind.subject?.tokens)
    }

    @Test
    fun `a general question finds its subject from the tagger or the book's names`() {
        assertEquals(listOf("alice"), subject("What did Alice drink?")?.tokens)
        assertEquals(listOf("duchess"), subject("What did the Duchess do?", listOf("duchess"))?.tokens)
        // A multi-word name the book knows stays one subject.
        assertEquals(listOf("white", "rabbit"), subject("What did the White Rabbit drop?", listOf("white rabbit"))?.tokens)
    }

    @Test
    fun `bare capitalisation is not a subject`() {
        assertNull(subject("Why did she cry so much?"))
    }

    // One kinship vocabulary

    @Test
    fun `every relation a reader names reaches the kinship path`() {
        for (word in listOf(
            "relative", "relatives", "relation", "kin", "family",
            "grandparent", "grandparents", "companion", "grandmothers", "wives",
            "widows", "baby", "brother", "cousin", "friend",
        )) {
            assertNotNull(word, KinRelation.matching(word))
        }
    }

    @Test
    fun `a relation's spellings all belong to its own group`() {
        for (relation in KinRelation.all) {
            val outside = relation.forms.filter { it !in relation.group }
            assertTrue("${relation.word} has $outside outside its group", outside.isEmpty())
            assertTrue(relation.word, relation.word in relation.group)
        }
    }

    @Test
    fun `no spelling names two relations, so the order of the table decides nothing`() {
        val owner = HashMap<String, String>()
        for (relation in KinRelation.all) {
            for (form in relation.forms) {
                owner[form]?.let { fail("$form is both $it and ${relation.word}") }
                owner[form] = relation.word
            }
        }
        // And the whole set is what the query asks for when the reader named no
        // relation at all.
        assertEquals(owner.keys, KinRelation.allForms.toSet())
    }

    @Test
    fun `asking about a relative is a kinship question`() {
        for (question in listOf(
            "Who is Ryn's relative?", "Who is Ryn's family?",
            "Who is Ryn's grandparent?", "Who is Ryn's companion?",
        )) {
            assertEquals(question, "kinship", kind(question, listOf("ryn")).label)
        }
    }

    // Questions that are not questions

    /**
     * A typed question crashed the Swift app: a copula ending in *s* followed
     * by an apostrophe is a possessive at word zero, and the yes/no scan then
     * took an impossible slice.
     */
    @Test
    fun `a question that opens with a possessive is classified, not trapped`() {
        for (question in listOf("Was' brother Dask?", "Is' brother Dask?", "Does' sister Alice?")) {
            assertEquals(question, "kinship", kind(question).label)
        }
    }

    @Test
    fun `a real yes or no question still finds the person being asked about`() {
        val kind = kind("Is Dask Ryn's brother?", listOf("ryn", "dask")) as? QuestionKind.Kinship
            ?: return fail("expected kinship")
        assertEquals(listOf("ryn"), kind.subject.tokens)
        assertEquals("brother", kind.relation?.word)
        assertEquals(listOf("dask"), kind.other?.tokens)
        assertEquals(QuestionKind.KinshipForm.YES_NO, kind.form)
    }

    // Recap

    @Test
    fun `recap still wins over everything`() {
        assertEquals(QuestionKind.Recap, kind("What has happened so far?"))
        assertTrue(QueryTerms.extract("Summarise the story so far").isRecap)
        assertFalse(QueryTerms.extract("Who is Ryn?").isRecap)
    }

    // "The author" is not a name

    @Test
    fun `no question can make a word for the book's maker its subject`() {
        for (question in listOf(
            "What happened to the author's son?",
            "Who is the author's father?",
            "Who is the author?",
            "Tell me about the narrator",
            "How are the author and the editor related?",
            "What does the Poet think?",
        )) {
            val tokens = subject(question)?.tokens.orEmpty()
            assertTrue("$question → subject $tokens", tokens.all { !QueryTerms.isBookRole(it) })
        }
    }

    @Test
    fun `a role word the index knows as a name is still not a name`() {
        val kind = kind("Who is the author?", listOf("author", "josiah"))
        assertEquals("general", kind.label)
        assertNull(kind.subject)
    }

    @Test
    fun `a role word beside a real name leaves the real name as the subject`() {
        assertEquals(listOf("frankenstein"), kind("Who is the author of Frankenstein?", listOf("frankenstein")).subject?.tokens)
        // And the kinship reading survives when the owner really is a person.
        val kinship = kind("Who is Josiah's father?", listOf("josiah"))
        assertEquals("kinship", kinship.label)
        assertEquals(listOf("josiah"), kinship.subject?.tokens)
    }

    // The question is the clause it opens with

    /** The worst question in the full-book trial, at 2.04/10. */
    @Test
    fun `a kinship aside does not become the question`() {
        val question = "wait who is corran again? he's aldric's brother right? but isn't he one of the ministry people"
        val kind = kind(question, listOf("corran", "aldric")) as? QuestionKind.Identity
            ?: return fail("classified as ${kind(question, listOf("corran", "aldric")).label}")
        assertEquals(listOf("corran"), kind.subject.tokens)
        assertTrue(kind.subject.isKnownName)

        // And this is the reading it replaced: read all at once, the question is
        // a kinship question about the wrong person entirely.
        val hijacked = QuestionReader.kinship(QuestionReader.words(question), Vocabulary(known = setOf("corran", "aldric")))
        assertEquals(listOf("aldric"), hijacked?.subject?.tokens)
    }

    @Test
    fun `a leading kinship clause still wins`() {
        for (question in listOf(
            "Who is the brother of Ryn?",
            "Who is Ryn's brother? I forget.",
            "Who was Ryn's younger brother? he gets mentioned early on",
        )) {
            val kind = kind(question, listOf("ryn"))
            if (kind !is QuestionKind.Kinship) {
                fail("$question classified as ${kind.label}")
                continue
            }
            assertEquals(question, listOf("ryn"), kind.subject.tokens)
            assertEquals(question, "brother", kind.relation?.word)
        }
    }

    @Test
    fun `a leading clause that names two people is not an identity question`() {
        val subject = subject(
            "who is dask to ryn again? her brother? and what happened to him",
            listOf("ryn", "dask", "torv", "halden"),
        )
        assertEquals("the subject is the person asked about", listOf("dask"), subject?.tokens)
    }

    @Test
    fun `a two-word name is still one subject`() {
        assertEquals(listOf("white", "rabbit"), subject("Who is the White Rabbit?", listOf("white rabbit", "rabbit"))?.tokens)
        assertEquals(listOf("white", "rabbit"), subject("Who is the White Rabbit?", listOf("white", "rabbit"))?.tokens)
    }

    @Test
    fun `a kinship question after an aside is still found`() {
        val kind = kind("sorry i lost track. who is Ryn's brother?", listOf("ryn")) as? QuestionKind.Kinship
            ?: return fail("expected kinship")
        assertEquals(listOf("ryn"), kind.subject.tokens)
        assertEquals("brother", kind.relation?.word)
    }

    @Test
    fun `an identity question after an aside is still found`() {
        assertEquals(listOf("ryn"), kind("wait. who is Ryn?", listOf("ryn")).subject?.tokens)
        assertEquals("identity", kind("ok. tell me about Dinah").label)
    }

    /**
     * The property the whole change rests on: for a question of one sentence
     * the leading clause *is* the question, so classification runs on the
     * identical list it ran on before.
     */
    @Test
    fun `one sentence is one clause`() {
        for (question in listOf(
            "Who is Ryn?",
            "Who is Mr. Darcy's sister?",
            "Who was the Iron Warden really?",
            "Is Dask Ryn's brother?",
            "How are Ryn and Marek related?",
            "What is Alice's cat called?",
            "Tell me about Dinah",
            "Who is the man standing by the river bank waiting?",
            "Was' brother Dask?",
        )) {
            val sanitised = QueryTerms.sanitise(question)
            assertEquals(question, 1, SentenceSplitter.ranges(sanitised).size)
            // Null, not "the whole question".
            assertNull(question, QuestionReader.leadingClauseText(sanitised))
        }
    }

    @Test
    fun `a leading filler is dropped`() {
        for (question in listOf("so who is Ryn?", "wait who is Ryn?", "um, who is Ryn?")) {
            val kind = kind(question, listOf("ryn"))
            if (kind !is QuestionKind.Identity) {
                fail("$question classified as ${kind.label}")
                continue
            }
            assertEquals(question, listOf("ryn"), kind.subject.tokens)
        }
        // Deliberately not fillers: both are ordinary nouns.
        assertFalse("well" in QuestionReader.leadingFillers)
        assertFalse("right" in QuestionReader.leadingFillers)
    }

    @Test
    fun `hesitation is dropped in front of every kind of question`() {
        for (question in listOf(
            "wait is Dask Ryn's brother?",
            "so, was Dask Ryn's brother?",
            "wait is Dask Ryn's brother? I forget.",
        )) {
            val kind = kind(question, listOf("ryn", "dask"))
            if (kind !is QuestionKind.Kinship) {
                fail("$question classified as ${kind.label}")
                continue
            }
            assertEquals(question, listOf("ryn"), kind.subject.tokens)
            assertEquals(question, "brother", kind.relation?.word)
            assertEquals(question, listOf("dask"), kind.other?.tokens)
            assertEquals(question, QuestionKind.KinshipForm.YES_NO, kind.form)
        }
        val related = kind("so how are Ryn and Marek related?", listOf("ryn", "marek")) as? QuestionKind.Kinship
            ?: return fail("expected kinship")
        assertEquals(listOf("ryn"), related.subject.tokens)
        assertEquals(listOf("marek"), related.other?.tokens)
        assertEquals(QuestionKind.KinshipForm.HOW_RELATED, related.form)
    }
}
