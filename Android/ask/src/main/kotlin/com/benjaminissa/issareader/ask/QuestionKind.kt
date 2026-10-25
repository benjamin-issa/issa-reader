package com.benjaminissa.issareader.ask

/**
 * Who or what a question is *about*, in the form retrieval can use.
 *
 * The tokens are what the FTS pattern is built from, so they are folded and
 * stripped of the possessive: the reader who types "Ryn's" is asking about
 * `ryn`, and a pattern built from `ryn's` reaches nothing — SQLite's tokeniser
 * reads the apostrophe as a word break, which is the bug that made "What is
 * the name of Ryn's brother?" search for `ryn OR s`.
 */
data class Subject(
    /**
     * The subject as the reader wrote it, articles removed: "White Rabbit",
     * "Ryn", "the Duchess" → "Duchess". Shown nowhere; used to compose the
     * deterministic kinship answer, which has to spell the name their way.
     */
    val display: String,
    /**
     * Folded, lowercased, possessive-stripped. Every one of these is required
     * of a passage before it is even considered.
     */
    val tokens: List<String>,
    /**
     * Whether the book's own name table recognises this, which is the only
     * reliable signal for an invented name: a general-purpose tagger finds
     * neither "RYN" nor "White Rabbit" nor "Duchess" as a person.
     */
    val isKnownName: Boolean,
) {
    /**
     * The last token, which is the head of a multi-word name ("Rabbit" of
     * "White Rabbit") and therefore what the book usually calls it after the
     * introduction.
     */
    val head: String get() = tokens.lastOrNull() ?: ""
}

/**
 * One family word a reader can ask about, with the spellings a book might use
 * and the group that reaches its neighbours.
 *
 * The group is recall, not synonymy: a novel introduces a brother once and
 * then uses his name, so a question asked forty pages later matches the
 * introduction only by way of "sibling", "sister", "brothers".
 */
data class KinRelation(
    /** The canonical singular, which is what the deterministic answer says. */
    val word: String,
    /** Every spelling of this one relation. */
    val forms: List<String>,
    /** The whole [Kinship] group it belongs to. */
    val group: List<String>,
) {
    companion object {
        /**
         * The relations a question can name, read out of [Kinship].
         *
         * The spellings are here because a group cannot supply them — a
         * brother and a sister are one group and two relations — but the
         * *group* is not, and neither is the vocabulary. Walking [Kinship.all]
         * is what makes the two agree: a relation exists exactly where a group
         * has a word for it.
         *
         * Order follows the groups, which is safe because [matching] compares
         * whole spellings rather than prefixes — "grandmother" is not a form of
         * "mother" — and `QuestionKindTest` asserts no spelling names two
         * relations, so there is nothing for an order to decide.
         */
        val all: List<KinRelation> by lazy {
            val spellings = mapOf(
                "grandmother" to listOf("grandmother", "grandmothers", "grandma"),
                "grandfather" to listOf("grandfather", "grandfathers", "grandpa"),
                "grandparent" to listOf("grandparent", "grandparents"),
                "granddaughter" to listOf("granddaughter", "granddaughters"),
                "grandson" to listOf("grandson", "grandsons"),
                "grandchild" to listOf("grandchild", "grandchildren"),
                "brother" to listOf("brother", "brothers"),
                "sister" to listOf("sister", "sisters"),
                "sibling" to listOf("sibling", "siblings"),
                "mother" to listOf("mother", "mothers", "mum", "mama", "mamma"),
                "father" to listOf("father", "fathers", "papa", "dad"),
                "parent" to listOf("parent", "parents"),
                "son" to listOf("son", "sons"),
                "daughter" to listOf("daughter", "daughters"),
                "child" to listOf("child", "children", "baby", "babies"),
                "husband" to listOf("husband", "husbands"),
                "wife" to listOf("wife", "wives"),
                "spouse" to listOf("spouse", "spouses"),
                "widow" to listOf("widow", "widows", "widower", "widowers"),
                "aunt" to listOf("aunt", "aunts"),
                "uncle" to listOf("uncle", "uncles"),
                "niece" to listOf("niece", "nieces"),
                "nephew" to listOf("nephew", "nephews"),
                "cousin" to listOf("cousin", "cousins"),
                "relative" to listOf("relative", "relatives", "relation", "relations", "kin"),
                "family" to listOf("family", "families"),
                "friend" to listOf("friend", "friends", "friendship"),
                "companion" to listOf("companion", "companions"),
            )
            Kinship.all.flatMap { group ->
                group.mapNotNull { word -> spellings[word]?.let { KinRelation(word, it, group) } }
            }
        }

        /**
         * Every spelling of every relation, for the query that has to reach a
         * passage using a word the question never said.
         */
        val allForms: List<String> by lazy {
            val seen = HashSet<String>()
            val ordered = ArrayList<String>()
            for (relation in all) for (form in relation.forms) if (seen.add(form)) ordered.add(form)
            ordered
        }

        fun matching(token: String): KinRelation? = all.firstOrNull { token in it.forms }
    }
}

/**
 * What the reader actually asked, and therefore how the book is searched.
 *
 * Classification exists because BM25 over an OR of every question word answers
 * a different question from the one asked. Measured on *The Hero of Ages* at
 * the Epilogue: "What is the name of Ryn's brother?" ranked the sentence that
 * says "Her brother, Dask, had trained her…" fiftieth in a pool capped at
 * forty, and the model — handed six passages, five of which never said "Ryn" —
 * answered "Sorrel". Knowing the question is a kinship question is what lets
 * retrieval require the subject and then look at sentences instead of
 * paragraphs.
 */
sealed interface QuestionKind {
    /** "What has happened so far?" — no search terms at all; the passages before the boundary are the answer. */
    data object Recap : QuestionKind {
        override val subject: Subject? get() = null
    }

    /** "Who is X?", "What is the X?", "Tell me about X". */
    data class Identity(override val subject: Subject) : QuestionKind

    /** "X's brother", "the brother of X", "how are X and Y related", "is Y X's brother". */
    data class Kinship(
        override val subject: Subject,
        val relation: KinRelation?,
        val other: Subject?,
        val form: KinshipForm,
    ) : QuestionKind

    /**
     * Everything else. The subject, when there is one, is still required of
     * every passage: "What is Alice's cat called?" is not about cats.
     */
    data class General(override val subject: Subject?) : QuestionKind

    /**
     * What an answer to a kinship question would have to look like, which
     * decides whether the deterministic extractor may answer at all.
     */
    enum class KinshipForm {
        /**
         * "Who is X's brother?" — a name is the answer, so one unambiguous name
         * in the evidence can be answered without the model.
         */
        WHO_IS,

        /** "Is Y X's brother?" — the answer is yes or no, which needs reading. */
        YES_NO,

        /** "How are X and Y related?" — needs prose. */
        HOW_RELATED,
    }

    /** The subject every branch except [Recap] may or may not have. */
    val subject: Subject?

    val isRecap: Boolean get() = this == Recap

    /**
     * For logs and for the diagnostic run, which has to say which path a
     * question took without printing the question.
     */
    val label: String
        get() = when (this) {
            Recap -> "recap"
            is Identity -> "identity"
            is Kinship -> "kinship"
            is General -> "general"
        }
}

/**
 * What this book calls people, as far as the reader has got.
 *
 * Two lists rather than one, because they fail in opposite directions. A
 * general-purpose name finder finds ordinary names and misses every invented
 * one, while the book's own table knows exactly the invented ones and nothing
 * about a name the reader has not reached yet. A subject has to be allowed to
 * come from either.
 */
internal data class Vocabulary(
    /**
     * Folded name tokens the index has seen before the boundary, including the
     * multi-word spellings ("white rabbit").
     */
    val known: Set<String> = emptySet(),
    /**
     * Folded tokens [NameFinder] found as people in this question, plus the
     * ones the known list promoted.
     */
    val tagged: Set<String> = emptySet(),
) {
    fun isName(token: String): Boolean {
        // The one choke point both lists funnel through, so `bookRoles` is
        // enforced here rather than at each of the three call sites. Gutenberg
        // prints "**Author**: Benjamin Franklin" on its own header page, so
        // `author` really is in a Franklin index's name table — and without
        // this the book's own boilerplate teaches the classifier that "the
        // author" is somebody it has met.
        if (QueryTerms.isBookRole(token)) return false
        return token in tagged || token in known ||
            known.any { it.startsWith("$token ") || it.endsWith(" $token") }
    }

    /** Whether the book itself knows this spelling — the signal that survives an invented name. */
    fun isKnownName(phrase: String, tokens: List<String>): Boolean {
        if (phrase in known) return true
        if (tokens.any { it in known }) return true
        return known.any { it.startsWith("$phrase ") || it.endsWith(" $phrase") }
    }
}

internal object QuestionReader {
    /**
     * Contractions that hide an identity lead-in. "Who's Ryn?" is "Who is
     * Ryn?", and reading it as one word loses the whole question shape.
     */
    val expansions: Map<String, List<String>> = mapOf(
        "who's" to listOf("who", "is"), "what's" to listOf("what", "is"),
        "whos" to listOf("who", "is"), "whats" to listOf("what", "is"),
    )

    /**
     * Splits the sanitised question into words the classifier can reason
     * about.
     *
     * Through [Words], which is also what splits the book's own sentences.
     * The two used to be separate functions differing in one character, and
     * [KinshipExtractor] compares their output against each other — see the
     * header of [Words].
     */
    fun words(question: String): List<Words.Word> {
        val out = ArrayList<Words.Word>()
        for (chunk in question.splitOnWhitespace()) {
            val display = chunk.trimmingCharacters(Words.EDGE_PUNCTUATION)
            // "Who's Ryn?" is two words, and only the split form reaches the
            // "who is" lead-in the identity path matches on.
            val expanded = expansions[display.lowercasedSwift()]
            if (expanded != null) {
                for (part in expanded) {
                    out.add(
                        Words.Word(
                            display = part, token = part, isPossessive = false,
                            isCapitalised = false, followedByComma = false,
                        ),
                    )
                }
                continue
            }
            Words.word(chunk)?.let(out::add)
        }
        return out
    }

    // Classifying

    /**
     * The question's shape.
     *
     * Order matters. Recap first, because it has no subject at all; kinship
     * before identity, because "Who is Alice's sister?" is both a "who is"
     * question and a kinship one and only the kinship reading finds the
     * sentence that answers it.
     *
     * **The leading clause decides, and the whole question is consulted only
     * when the leading clause claims nothing.** A reader who has lost the
     * thread does not type one clean sentence. Measured against a full-length
     * novel: "wait who is corran again? he's aldric's brother right? but isn't
     * he one of the ministry people" was read as a kinship question about
     * `aldric`, so retrieval hunted family words near Aldric and returned his
     * two earliest mentions. The Ministry storyline the reader was asking
     * about was never retrieved; four settings answered "The story hasn't
     * revealed that yet" about a character named 157 times in what that
     * reader had read. The aside is the reader checking their own memory, not
     * the question — and the question is the clause they opened with.
     *
     * The spoiler gate does not follow the clause: it reads every sentence of
     * the question whichever one decided the kind, because an aside can name
     * somebody too — see [QueryTerms.nameCandidates].
     */
    fun kind(question: String, vocabulary: Vocabulary): QuestionKind {
        if (QueryTerms.isRecapQuestion(question)) return QuestionKind.Recap
        // Stripped once, here, for every reading below. The leading clause is
        // re-tokenised from its own substring, so it carries its own
        // hesitation and has to be stripped separately.
        val words = droppingLeadingFillers(words(question))
        if (words.isEmpty()) return QuestionKind.General(null)
        val clause = leadingClauseText(question)
        val leading = clause?.let { droppingLeadingFillers(words(it)) } ?: words

        kinship(leading, vocabulary)?.let { return it }
        val identity = identity(leading, vocabulary)
        if (identity is QuestionKind.Identity && namesOneSubject(identity.subject, vocabulary)) return identity
        kinship(words, vocabulary)?.let { return it }
        identity(words, vocabulary)?.let { return it }
        return QuestionKind.General(generalSubject(words, vocabulary))
    }

    /**
     * Whether an identity subject names one thing, rather than stitching two
     * together across a connector.
     *
     * "who is dask to ryn again? her brother?" reads, on its leading clause
     * alone, as an identity question about `["dask", "ryn"]` — and a two-token
     * subject is required of every passage *together*, so retrieval kept the
     * paragraphs that name both and lost every sentence that says what Dask
     * was to her. It is a kinship question wearing an identity question's
     * clothes, and the reader's own next clause says which.
     *
     * Counting known names rather than tokens, because a real multi-word name
     * has one: the index knows "rabbit", not "white". And a subject rejected
     * here is not thrown away — it falls through to the whole-question
     * reading, which for a one-clause question is the same words and so the
     * same answer. Only a question with a later clause can be re-read by this.
     */
    fun namesOneSubject(subject: Subject, vocabulary: Vocabulary): Boolean =
        subject.tokens.count { it in vocabulary.known } < 2

    /**
     * The question's first sentence, or null when the question is one sentence.
     *
     * Split with [SentenceSplitter], which is the splitter the book's own
     * sentences go through, so "Who is Mr. Darcy's sister?" is one clause here
     * for the same reason it is one sentence there.
     *
     * **Null rather than the whole question**, so the caller can tell the two
     * apart — a clause equal to the question is indistinguishable from no
     * clause. Classification of a one-sentence question therefore runs on the
     * caller's own list, unchanged from before any of this existed.
     *
     * Commas are deliberately not clause boundaries. Splitting on them too
     * would reach more of the questions readers type, and it would cost
     * exactly the property this paragraph is about.
     */
    fun leadingClauseText(question: String): String? {
        val sentences = SentenceSplitter.ranges(question)
        if (sentences.size <= 1) return null
        val first = sentences.first()
        return question.substring(first.location, first.end)
    }

    // Kinship

    /**
     * Adjectives a reader puts between the owner and the relation. Without
     * these "Ryn's younger brother" loses its owner and becomes a general
     * question about brothers.
     */
    val kinshipAdjectives: Set<String> = setOf(
        "own", "elder", "older", "younger", "little", "big", "twin", "half",
        "only", "dear", "beloved", "poor", "eldest", "youngest", "step",
    )

    fun kinship(words: List<Words.Word>, vocabulary: Vocabulary): QuestionKind? {
        val kinIndex = words.indexOfFirst { KinRelation.matching(it.token) != null }
        if (kinIndex < 0) return howRelated(words, vocabulary)
        val relation = KinRelation.matching(words[kinIndex].token)

        // "Ryn's brother", "Ryn's younger brother".
        var ownerIndex: Int? = null
        var scan = kinIndex - 1
        while (scan >= 0 && words[scan].token in kinshipAdjectives) scan -= 1
        // The possessive alone is not enough. "Who is the author's father?"
        // made `author` the owner, so every passage had to contain the word,
        // and a Gutenberg memoir answered from its own boilerplate — see
        // `QueryTerms.bookRoles`. Rejecting the owner drops through to the
        // general path, which ranks the kinship group and finds Josiah.
        if (scan >= 0 && words[scan].isPossessive && !QueryTerms.isBookRole(words[scan].token)) {
            ownerIndex = scan
        }

        // "the brother of Ryn".
        if (ownerIndex == null && kinIndex + 2 < words.size && words[kinIndex + 1].token == "of") {
            var candidate = kinIndex + 2
            if (words[candidate].token in setOf("the", "a", "an") && candidate + 1 < words.size) candidate += 1
            if (isNameLike(words[candidate], candidate, vocabulary)) ownerIndex = candidate
        }
        if (ownerIndex == null) return howRelated(words, vocabulary)

        val owner = subject(listOf(words[ownerIndex]), vocabulary)
        // "Is Dask Ryn's brother?" — a yes/no question, which the extractor
        // must not answer with a name.
        //
        // `ownerIndex > 1`, because the owner can be the very first word: a
        // question that *opens* with a possessive gives `ownerIndex == 0`, and
        // `words[1 until 0]` has to be no range at all. `Was' brother Dask?`
        // reached it — `Words.EDGE_PUNCTUATION` deliberately keeps a trailing
        // apostrophe, because that is what says "Vins'" is possessive, and
        // `POSSESSIVE_SUFFIXES` includes `s'`. A typed question crashed the
        // Swift app.
        val lead = words.firstOrNull()?.token
        if (ownerIndex > 1 && lead in setOf("is", "was", "are", "were", "does", "did")) {
            val between = (1 until ownerIndex).firstOrNull { isNameLike(words[it], it, vocabulary) }
            if (between != null) {
                return QuestionKind.Kinship(
                    subject = owner, relation = relation,
                    other = subject(listOf(words[between]), vocabulary),
                    form = QuestionKind.KinshipForm.YES_NO,
                )
            }
        }
        return QuestionKind.Kinship(subject = owner, relation = relation, other = null, form = QuestionKind.KinshipForm.WHO_IS)
    }

    /**
     * "How are X and Y related?" — no possessive and no relation noun, but
     * unmistakably a kinship question, and the two names are what to search
     * for together.
     */
    fun howRelated(words: List<Words.Word>, vocabulary: Vocabulary): QuestionKind? {
        val tokens = words.map { it.token }
        if (tokens.firstOrNull() != "how" || ("related" !in tokens && "relation" !in tokens)) return null
        val names = words.withIndex().filter { isNameLike(it.value, it.index, vocabulary) }.map { it.value }
        if (names.size < 2) return null
        return QuestionKind.Kinship(
            subject = subject(listOf(names[0]), vocabulary),
            relation = null,
            other = subject(listOf(names[1]), vocabulary),
            form = QuestionKind.KinshipForm.HOW_RELATED,
        )
    }

    // Identity

    /** The openings that mean "tell me who this is". Longest first, so "tell me about" is not read as nothing. */
    val identityLeadIns: List<List<String>> = listOf(
        listOf("tell", "me", "about"), listOf("tell", "me", "who"),
        listOf("who", "exactly", "is"), listOf("who", "is"), listOf("who", "was"),
        listOf("who", "are"), listOf("who", "were"),
        listOf("what", "is"), listOf("what", "was"), listOf("what", "are"), listOf("what", "were"),
    )

    /** Filler that trails an identity question without being part of the name. */
    val identityTrailers: Set<String> = setOf(
        "so", "far", "really", "actually", "exactly", "again", "please",
        "in", "the", "this", "book", "story", "novel", "anyway",
    )

    /**
     * Filler that opens a question without being part of it, mirroring
     * [identityTrailers] at the other end.
     *
     * A reader interrupting their own reading writes "wait who is corran
     * again?", and the lead-in table is matched against the *start* of the
     * question, so one word of hesitation is the difference between a name
     * lookup and a BM25 search over the whole sentence.
     *
     * `well` and `right` are deliberately absent. Both are ordinary nouns, and
     * a word in this set is dropped from the front of every question that
     * opens with it — including the reader asking what the well is.
     */
    val leadingFillers: Set<String> = setOf(
        "wait", "ok", "okay", "um", "uh", "hmm", "hey", "so", "and", "but",
        "also", "sorry", "actually",
    )

    /**
     * The question with its hesitation taken off the front.
     *
     * Once, in [kind], rather than inside the identity reading where it used
     * to live. Every other reading looks at a *position*: the yes/no scan
     * reads the first word to find its copula, [howRelated] for "how", and
     * [isNameLike] exempts index zero because every question capitalises its
     * first word. A filler left in front of the question moves all three by
     * one, so "wait is Dask Ryn's brother?" was read as `WHO_IS` and answered
     * "Ryn's brother is Dask." to a question that asked whether he was.
     * [Words.word] has already trimmed edge punctuation, so "so," strips like
     * "so".
     */
    fun droppingLeadingFillers(words: List<Words.Word>): List<Words.Word> {
        var start = 0
        while (start < words.size && words[start].token in leadingFillers) start += 1
        return if (start == 0) words else words.subList(start, words.size).toList()
    }

    /**
     * The most content words a subject can be before this stops being a
     * question about a person and starts being a question about a situation.
     */
    const val maximumSubjectTokens = 4

    fun identity(words: List<Words.Word>, vocabulary: Vocabulary): QuestionKind? {
        // The hesitation is already off the front: [kind] strips it for every
        // reading.
        val tokens = words.map { it.token }
        val leadIn = identityLeadIns.firstOrNull { leadIn ->
            tokens.size >= leadIn.size && tokens.subList(0, leadIn.size) == leadIn
        } ?: return null

        var rest = words.drop(leadIn.size)
        while (rest.isNotEmpty() && rest.first().token in setOf("the", "a", "an")) rest = rest.drop(1)
        while (rest.isNotEmpty() && rest.last().token in identityTrailers) rest = rest.dropLast(1)
        if (rest.isEmpty()) return null
        // A possessive means the question is about somebody's *something*
        // ("What is Alice's cat called?"), not about who somebody is.
        if (rest.any { it.isPossessive }) return null

        // `bookRoles` dropped here rather than rejected outright, so "Who is
        // the author of Frankenstein?" still asks about Frankenstein while "Who
        // is the author?" is left with nothing and falls through to the general
        // path — which is the sensible degradation.
        val content = rest.filter {
            it.token !in QueryTerms.stopWords && it.token.graphemeCount() > 1 && !QueryTerms.isBookRole(it.token)
        }
        if (content.isEmpty() || content.size > maximumSubjectTokens) return null
        // "Who is the brother?" names nobody: requiring `brother` of every
        // passage would be a search dressed up as a name lookup, and BM25 with
        // the kinship expansion is the better answer to it.
        if (content.none { KinRelation.matching(it.token) == null }) return null

        val candidate = subject(content, vocabulary)
        // Capitalised, known to the book, or the only word in the question:
        // anything else ("Who is the man in the boat?") is a search, not a
        // name, and the general path handles it better.
        val capitalised = content.any { it.isCapitalised }
        if (!capitalised && !candidate.isKnownName && content.size != 1) return null
        return QuestionKind.Identity(candidate)
    }

    // General

    /**
     * A subject for an ordinary question: whoever owns the possessive, else
     * the first word the book or the name finder calls a person.
     *
     * Never bare capitalisation. "Is Alice British?" would otherwise search
     * for `british` as a required token and find nothing.
     */
    fun generalSubject(words: List<Words.Word>, vocabulary: Vocabulary): Subject? {
        // Never a `bookRoles` owner: "What happened to the author's son?" is
        // the reported bug, and the possessive is what made `author` the
        // subject every passage had to contain.
        words.firstOrNull { it.isPossessive && !QueryTerms.isBookRole(it.token) }?.let {
            return subject(listOf(it), vocabulary)
        }
        val found = words.indexOfFirst { vocabulary.isName(it.token) }
        if (found >= 0) {
            // A known name may be a phrase: "White Rabbit" is one subject, not
            // two, and requiring only "white" retrieves the wrong paragraphs.
            return subject(knownPhrase(found, words, vocabulary), vocabulary)
        }
        return null
    }

    /** The longest run of words from [start] that the name table knows as one name. */
    fun knownPhrase(start: Int, words: List<Words.Word>, vocabulary: Vocabulary): List<Words.Word> {
        var best = listOf(words[start])
        val phrase = mutableListOf(words[start])
        var index = start + 1
        while (index < words.size && phrase.size < 3) {
            phrase.add(words[index])
            if (phrase.joinToString(" ") { it.token } in vocabulary.known) best = phrase.toList()
            index += 1
        }
        return best
    }

    // Building a subject

    fun subject(words: List<Words.Word>, vocabulary: Vocabulary): Subject {
        val tokens = words.map { it.token }.filter { it.isNotEmpty() }
        val phrase = tokens.joinToString(" ")
        return Subject(
            display = words.joinToString(" ") { it.display },
            tokens = tokens,
            isKnownName = vocabulary.isKnownName(phrase, tokens),
        )
    }

    /**
     * Whether this word could be naming somebody: the book knows it, the name
     * finder found it, or it is capitalised somewhere other than the start of
     * the question.
     */
    fun isNameLike(word: Words.Word, index: Int, vocabulary: Vocabulary): Boolean {
        if (word.token in QueryTerms.stopWords || word.token.graphemeCount() <= 1) return false
        if (word.token in QueryTerms.capitalisedNonNames) return false
        // "the Author" is capitalised in plenty of prefaces, and the
        // capitalisation clause below would take it for a name on that alone.
        if (QueryTerms.isBookRole(word.token)) return false
        if (vocabulary.isName(word.token)) return true
        return word.isCapitalised && index > 0
    }
}
