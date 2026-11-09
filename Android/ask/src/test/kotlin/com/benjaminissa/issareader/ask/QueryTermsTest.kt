package com.benjaminissa.issareader.ask

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class QueryTermsTest {
    // Kinship

    @Test
    fun `a question about a cousin reaches passages about relatives`() {
        val terms = QueryTerms.extract("Who is Alice's cousin?")
        val expanded = terms.searchTokens.toSet()
        // A novel introduces a relative once and then uses their name.
        assertTrue("relative" in expanded)
        assertTrue("family" in expanded)
        assertEquals(1, terms.kinshipGroups.size)
    }

    @Test
    fun `kinship groups stay separate so the ranker can reward a whole one`() {
        val terms = QueryTerms.extract("Did her sister meet their mother?")
        assertEquals(2, terms.kinshipGroups.size)
        assertTrue(Kinship.groups(listOf("nephew")).first().contains("aunt"))
        assertTrue(Kinship.groups(listOf("rabbit")).isEmpty())
    }

    // Recap

    @Test
    fun `recap questions are recognised, ordinary ones are not`() {
        for (question in listOf(
            "What has happened so far?",
            "Can you summarise the story so far?",
            "Remind me what I've read",
            "Catch me up please",
        )) {
            assertTrue(question, QueryTerms.extract(question).isRecap)
        }
        assertFalse(QueryTerms.extract("Who is the Duchess?").isRecap)
        assertFalse(QueryTerms.extract("Why did Alice cry?").isRecap)
    }

    // Tokenising

    @Test
    fun `apostrophes, quotation marks and hyphens still make a valid FTS5 pattern`() {
        // The failure this guards against is silent: an unquoted apostrophe
        // makes SQLite read the rest of the query as a phrase, and the reader
        // gets an answer built from no excerpts at all rather than an error.
        val questions = listOf(
            "What is the Mock Turtle’s story?",
            "Why does she say \"curiouser and curiouser\"?",
            "Who lives in the Rabbit-Hole — and why?",
            "Alice's sister's book?",
            "NEAR(a b) AND *",
        )
        for (question in questions) {
            val terms = QueryTerms.extract(question)
            assertTrue(question, terms.searchTokens.isNotEmpty())
            // The builders production actually uses. A null here is retrieval
            // returning nothing and the reader being told "not yet".
            val any = FtsQuery.any(terms.searchTokens)
            val all = FtsQuery.all(terms.searchTokens)
            assertNotNull(question, any)
            assertNotNull(question, all)
            // Every token survives into the pattern, apostrophes and all.
            for (token in FtsQuery.usable(terms.searchTokens)) {
                assertTrue("$question: $token", any!!.rawPattern.contains(FtsQuery.quoted(token)))
            }
        }
        // Nothing but punctuation and operators: no tokens, said rather than
        // skipped past.
        for (degenerate in listOf("'''", "-- OR 1=1 --")) {
            assertTrue(degenerate, QueryTerms.extract(degenerate).searchTokens.isEmpty())
        }
    }

    @Test
    fun `a curly apostrophe and a straight one tokenise the same`() {
        assertEquals(QueryTerms.tokens("Alice's"), QueryTerms.tokens("Alice’s"))
        assertEquals(listOf("alice's"), QueryTerms.tokens("Alice’s"))
        // A leading quotation mark must not open a token, or FTS5 reads what
        // follows as a phrase.
        assertEquals(listOf("twas", "the", "queen"), QueryTerms.tokens("'twas the queen"))
    }

    @Test
    fun `diacritics fold, because the book may spell it either way`() {
        assertEquals(listOf("bronte"), QueryTerms.tokens("Brontë"))
    }

    @Test
    fun `a pasted paragraph is clamped rather than diluting the match`() {
        val long = "wonderland ".repeat(200)
        val terms = QueryTerms.extract(long)
        assertTrue(terms.question.graphemeCount() <= QueryTerms.maximumQuestionLength)
    }

    // Names

    @Test
    fun `a name the book knows is promoted even when the tagger misses it`() {
        // "Cheshire" is not a name any general-purpose tagger knows, and it is
        // exactly the kind of name readers ask about. The book's own name table
        // is what rescues it.
        val plain = QueryTerms.extract("Who is the Cheshire Cat?")
        val promoted = QueryTerms.extract("Who is the Cheshire Cat?", knownNames = listOf("Cheshire Cat"))
        assertFalse("cheshire" in plain.names)
        assertTrue("cheshire" in promoted.names)
    }

    @Test
    fun `a capitalised word mid-question is treated as a name to check for`() {
        assertEquals(listOf("cat", "cheshire"), QueryTerms.extract("Who is the Cheshire Cat?").nameCandidates)
        assertEquals(listOf("alice"), QueryTerms.extract("What did Alice follow down the hole?").nameCandidates)
        assertTrue(QueryTerms.extract("why did she cry?").nameCandidates.isEmpty())
        assertTrue(QueryTerms.extract("What has happened so far?").nameCandidates.isEmpty())
    }

    /**
     * A bare-name question has the name first. The first word was skipped
     * unconditionally, and the answer side exempted every word the question
     * contained, so "Cheshire Cat?" at the end of Chapter I probed only `cat`.
     */
    @Test
    fun `a name the question opens with is checked like any other`() {
        assertEquals(listOf("cat", "cheshire"), QueryTerms.extract("Cheshire Cat?").nameCandidates)
        assertEquals(listOf("bilbo"), QueryTerms.extract("Bilbo?").nameCandidates)
        assertEquals(listOf("mordor"), QueryTerms.extract("Mordor is where?").nameCandidates)
        // The words a question opens with anyway are still not names.
        assertEquals(listOf("alice"), QueryTerms.extract("Who is Alice?").nameCandidates)
        assertEquals(listOf("alice"), QueryTerms.extract("Does Alice cry?").nameCandidates)
        assertEquals(listOf("dinah"), QueryTerms.extract("Who's Dinah?").nameCandidates)
        assertTrue(QueryTerms.extract("Describe the garden.").nameCandidates.isEmpty())
        assertEquals(listOf("duchess"), QueryTerms.extract("Tell me about the Duchess.").nameCandidates)
    }

    @Test
    fun `structural capitals are not mistaken for characters`() {
        assertEquals(listOf("two"), QueryTerms.extract("What happens in Chapter Two?").nameCandidates)
        assertTrue(QueryTerms.extract("Did it happen on Tuesday?").nameCandidates.isEmpty())
    }

    /** The gate reads every sentence, whichever one the classifier decided on (R-04). */
    @Test
    fun `the spoiler gate reads every sentence, not only the classifier's clause`() {
        val aside = QueryTerms.extract("wait who is Marek again? Is he one of the Wardens?", knownNames = listOf("marek"))
        assertEquals("identity", aside.kind.label)
        // "Is" opens its sentence and is a function word; "Wardens" is a name.
        assertEquals(listOf("marek", "wardens"), aside.nameCandidates)

        // A question whose opening clause claims nothing is decided on the
        // whole question, and gated whole as before.
        val fellThrough = QueryTerms.extract("i lost track. Is Dask Ryn's brother?", knownNames = listOf("ryn", "dask"))
        assertEquals("kinship", fellThrough.kind.label)
        assertEquals(listOf("dask", "ryn"), fellThrough.nameCandidates)
    }

    // The possessive

    @Test
    fun `a possessive is stripped everywhere the name is used`() {
        val terms = QueryTerms.extract("What is the name of Ryn's brother?", knownNames = listOf("Ryn", "Dask"))
        assertTrue("ryn" in terms.terms)
        assertFalse("ryn's" in terms.terms)
        assertFalse("s" in terms.terms)
        assertTrue(terms.names.any { it.lowercase() == "ryn" })
        assertTrue("ryn" in terms.nameCandidates)
        assertFalse("ryn's" in terms.nameCandidates)
        assertEquals(listOf("ryn"), terms.subject?.tokens)
    }

    @Test
    fun `stripping the possessive leaves ordinary words alone`() {
        assertEquals("ryn", QueryTerms.strippingPossessive("ryn's"))
        assertEquals("alice", QueryTerms.strippingPossessive("alice's"))
        // `tokens` itself is untouched: the FTS patterns and the offset tests
        // are written against what it produces.
        assertEquals(listOf("ryn's"), QueryTerms.tokens("Ryn's"))
        assertEquals("its", QueryTerms.strippingPossessive("its"))
        assertEquals("o'clock", QueryTerms.strippingPossessive("o'clock"))
        assertEquals("as", QueryTerms.strippingPossessive("as"))
    }

    @Test
    fun `an answer's possessive is vetted as the name, not as the possessive`() {
        assertEquals(listOf("dask"), AskEngine.unvettedNames("She trusted Dask's word."))
    }

    @Test
    fun `search tokens are unique and lead with the question's own words`() {
        val terms = QueryTerms.extract("Who is the White Rabbit's friend?")
        assertEquals(terms.searchTokens.size, terms.searchTokens.toSet().size)
        assertEquals(terms.terms, terms.searchTokens.take(terms.terms.size))
    }

    // The sentence-opener list

    /**
     * Ordinary English words that are also names somebody has, named in
     * `sentenceOpeners`' own comment as deliberately absent and repeated here
     * so the two cannot drift.
     */
    private val namesPeopleAreCalled = setOf(
        "will", "may", "mark", "grace", "rose", "hope", "faith", "bill",
        "frank", "jack", "art", "dawn", "june", "pat", "sue", "victor",
    )

    @Test
    fun `no word on the sentence-opener list is a name anybody is called`() {
        val overlap = QueryTerms.sentenceOpeners.intersect(namesPeopleAreCalled)
        assertTrue("${overlap.sorted()} would be exempt sentence-initially for ever", overlap.isEmpty())
    }

    @Test
    fun `every sentence opener is lower case, so the guard's lookup can find it`() {
        assertTrue(QueryTerms.sentenceOpeners.all { it == it.lowercase() })
    }

    // Words that name the book's maker

    /** The retrieval bug behind "make the AI answers richer", measured on *Franklin*. */
    @Test
    fun `a word that names the book's maker is never a search token`() {
        for (question in listOf(
            "What happened to the author's son?",
            "Who is the narrator's father?",
            "What does the editor say about the poet?",
            "Is the translator reliable?",
        )) {
            val terms = QueryTerms.extract(question)
            val dropped = terms.searchTokens.toSet().intersect(QueryTerms.bookRoles)
            assertTrue("$question kept ${dropped.sorted()}", dropped.isEmpty())
        }
        // What is left is what the question was actually about.
        val terms = QueryTerms.extract("What happened to the author's son?")
        assertTrue("son" in terms.searchTokens)
        assertTrue("happened" in terms.searchTokens)
    }

    @Test
    fun `a book that prints the word in its own header cannot promote it`() {
        val terms = QueryTerms.extract("Who is the author's father?", knownNames = listOf("Author", "Josiah"))
        assertFalse(terms.names.any { it.lowercase() == "author" })
        assertFalse("author" in terms.searchTokens)
    }

    @Test
    fun `a capitalised role word is not a name the book has to have introduced`() {
        val terms = QueryTerms.extract("What does the Narrator think of Alice?")
        assertFalse("narrator" in terms.nameCandidates)
        assertTrue("alice" in terms.nameCandidates)
    }

    @Test
    fun `the role list is folded and singular-and-plural, or the lookup misses`() {
        assertTrue(QueryTerms.bookRoles.all { it == it.lowercase() })
        // The reported question wrote it as a possessive.
        assertTrue(QueryTerms.isBookRole("author's"))
        assertTrue(QueryTerms.isBookRole("Authors"))
        assertFalse(QueryTerms.isBookRole("authority"))
    }
}
