package com.benjaminissa.issareader.ask

/**
 * Reads a name out of a sentence that states a relationship.
 *
 * "What is the name of Ryn's brother?" is not a question a 3B model should be
 * asked. The book contains one sentence that answers it — "Her brother, Dask,
 * had trained her…" — and once retrieval has found that sentence, the answer
 * is a pattern match, not an inference. Handing it to the model instead costs
 * several seconds and introduces the possibility of "Sorrel".
 *
 * So the table below is short and deliberately literal, and everything about it
 * is tuned to fail *quietly*. Over-reach is a confident wrong answer with a
 * citation on it; under-reach is the model answering with the right sentence
 * still in front of it. Only the second of those is recoverable.
 */
object KinshipExtractor {
    /** One name the evidence states is the subject's relative. */
    data class Match(
        val name: String,
        /** Which piece of evidence said so, so the answer can cite it. */
        val evidenceIndex: Int,
    )

    /** Every distinct name the evidence names as this relative, first mention first. */
    fun names(
        subject: Subject,
        relation: KinRelation?,
        evidence: List<Evidence>,
        knownNames: Set<String> = emptySet(),
    ): List<Match> {
        val patterns = Patterns(subject)
        val found = ArrayList<Match>()
        val seen = HashSet<String>()
        // Kinship sentences only. A kinship question that found too little is
        // topped up with whole passages, and running a pattern table over a
        // paragraph finds every name standing near a family word — which is
        // two candidates, which declines, which throws away the answer the
        // book actually stated.
        for ((index, piece) in evidence.withIndex()) {
            if (piece.role != Evidence.Role.KINSHIP) continue
            val names = names(
                subject = subject, relation = relation, patterns = patterns,
                sentence = piece.sentenceText, preceding = piece.precedingText, knownNames = knownNames,
            )
            for (name in names) {
                if (seen.add(NameFinder.Name.key(name))) found.add(Match(name, index))
            }
        }
        return found
    }

    /**
     * The answer, when the evidence states exactly one.
     *
     * Only for "who is X's brother" — a yes/no question ("Is Dask Ryn's
     * brother?") and "how are they related" both need prose, and answering
     * either with a bare name is answering a question nobody asked. Two names
     * is the book naming two brothers, or the pattern matching something it
     * should not have; either way the model reads the sentences instead.
     */
    fun answer(
        subject: Subject,
        relation: KinRelation?,
        form: QuestionKind.KinshipForm,
        evidence: List<Evidence>,
        knownNames: Set<String> = emptySet(),
    ): AskAnswer? {
        if (form != QuestionKind.KinshipForm.WHO_IS || relation == null) return null
        val matches = names(subject, relation, evidence, knownNames)
        if (matches.size != 1) return null
        val match = matches.first()
        return AskAnswer(
            text = "${subject.display}'s ${relation.word} is ${match.name}.",
            // One-based, the way the prompt numbers its excerpts — and an index
            // into the very list handed in, which is why this is the one
            // citation in the app that is provably the sentence it came from.
            citations = listOf(match.evidenceIndex + 1),
            notYetRevealed = false,
            // No model composed this: the name was read out of a paragraph the
            // reader has already passed, and the frame around it is a format
            // string. Saying "Generated on device" under it would be claiming
            // credit for the book.
            origin = AskAnswer.Origin.BOOK,
        )
    }

    // One sentence

    /**
     * Internal rather than private because [EvidenceFinder.kinship] ranks with
     * it: a sentence this reads a name out of is kept ahead of one that only
     * carries the family word.
     */
    internal fun names(
        subject: Subject,
        relation: KinRelation?,
        patterns: Patterns,
        sentence: String,
        preceding: String?,
        knownNames: Set<String>,
    ): List<String> {
        val words = Words.split(sentence)
        if (words.isEmpty()) return emptyList()
        val namesSubject = patterns.mentions(EvidenceFinder.fold(sentence))
        val kinWords = relation?.let { (it.forms + it.group).toSet() } ?: KinRelation.allForms.toSet()

        val found = ArrayList<String>()
        for ((index, word) in words.withIndex()) {
            if (word.token !in kinWords) continue
            if (isNegated(words, index)) continue

            // Everything in the table has either the subject's possessive or a
            // pronoun immediately before the relation, once the adjectives
            // ("her own younger brother") are stepped over.
            var owner = index - 1
            while (owner >= 0 && words[owner].token in adjectives) owner -= 1
            if (owner < 0) continue
            val ownerWord = words[owner]

            if (ownerWord.isPossessive && ownerWord.token in subject.tokens) {
                // "X's KIN, NAME" · "NAME, X's KIN" · "NAME was X's KIN" ·
                // "X's KIN was called NAME"
                found.addAll(candidates(words, index, owner, subject, kinWords, knownNames))
            } else if (ownerWord.token in pronouns) {
                // "PRON KIN, NAME" · "NAME, PRON KIN", and only where the
                // pronoun can only be the subject: one sentence of reach,
                // because two is a guess.
                if (!namesSubject && !onlyNames(subject, preceding, patterns, knownNames)) continue
                found.addAll(candidates(words, index, owner, subject, kinWords, knownNames))
            }
        }
        return found
    }

    /** The names sitting in the places the table allows. */
    internal fun candidates(
        words: List<Words.Word>,
        kin: Int,
        owner: Int,
        subject: Subject,
        kinWords: Set<String>,
        knownNames: Set<String>,
    ): List<String> {
        val found = ArrayList<String>()
        fun valid(index: Int): String? = name(words, index, subject, kinWords, knownNames)

        // "…her brother, Dask, had trained her" — the appositive, which is how
        // a novel most often states a relationship.
        if (words[kin].followedByComma) valid(kin + 1)?.let(found::add)

        // "Dask, her brother, said nothing" — the appositive the other way up.
        if (owner > 0 && words[owner - 1].followedByComma) {
            nameEnding(words, owner - 1, subject, kinWords, knownNames)?.let(found::add)
        }

        // "Dask was her brother."
        if (owner > 1 && words[owner - 1].token in copulas) {
            nameEnding(words, owner - 2, subject, kinWords, knownNames)?.let(found::add)
        }

        // "Her brother was called Dask." / "Her brother is Dask."
        if (kin + 1 < words.size && words[kin + 1].token in copulas) {
            var start = kin + 2
            if (start < words.size && words[start].token in setOf("called", "named")) start += 1
            valid(start)?.let(found::add)
        }
        return found
    }

    // What counts as a name

    /** A capitalised one- or two-word name beginning at [index]. */
    internal fun name(
        words: List<Words.Word>,
        index: Int,
        subject: Subject,
        kinWords: Set<String>,
        knownNames: Set<String>,
    ): String? {
        var start = index
        if (start < 0 || start >= words.size) return null
        // "Mr. Rabbit" and "Rabbit" are one person; the honorific is not part
        // of the answer.
        if (words[start].token in NameFinder.honorifics && start + 1 < words.size) start += 1
        if (!isName(words, start, subject, kinWords, knownNames)) return null
        var display = words[start].display
        // A second capital that is not a new clause: "Dask Venture", not
        // "Dask, Aldric".
        if (!words[start].followedByComma && start + 1 < words.size &&
            isName(words, start + 1, subject, kinWords, knownNames)
        ) {
            display += " " + words[start + 1].display
        }
        return display
    }

    /** The same, for a name that *ends* at [index] — the appositive read backwards. */
    internal fun nameEnding(
        words: List<Words.Word>,
        index: Int,
        subject: Subject,
        kinWords: Set<String>,
        knownNames: Set<String>,
    ): String? {
        if (index < 0 || index >= words.size) return null
        if (index > 0 && isName(words, index - 1, subject, kinWords, knownNames) && !words[index - 1].followedByComma) {
            return name(words, index - 1, subject, kinWords, knownNames)
        }
        return name(words, index, subject, kinWords, knownNames)
    }

    internal fun isName(
        words: List<Words.Word>,
        index: Int,
        subject: Subject,
        kinWords: Set<String>,
        knownNames: Set<String>,
    ): Boolean {
        if (index < 0 || index >= words.size) return false
        val word = words[index]
        if (!word.isCapitalised) return false
        if (word.display.codePointList().count(::isSwiftLetter) < 2) return false
        if (word.token in subject.tokens) return false
        if (word.token in kinWords || word.token in pronouns) return false
        if (word.token in QueryTerms.stopWords) return false
        if (word.token in QueryTerms.capitalisedNonNames) return false
        if (word.token in NameFinder.honorifics) return false
        // Every sentence starts with a capital, so the first word is only a
        // name when the book has already used it as one.
        if (index == 0) return word.token in knownNames
        return true
    }

    /**
     * Whether the preceding sentence names the subject and nobody else.
     *
     * One sentence of reach and no ambiguity in it. "Ryn turned away. Aldric
     * watched. Her brother, Dask, …" must not answer, because "her" is as
     * likely to be somebody else's.
     */
    internal fun onlyNames(subject: Subject, preceding: String?, patterns: Patterns, knownNames: Set<String>): Boolean {
        if (preceding == null) return false
        if (!patterns.mentions(EvidenceFinder.fold(preceding))) return false
        // A competing *person*, not a competing capital. "Ryn had grown up on
        // the streets of Ardmoor" has one person in it and one place, and a
        // rule that counted capitals would decline every sentence that
        // mentioned where it happened — which is most of them.
        for (found in NameFinder.names(preceding, spineIndex = 0)) {
            val tokens = QueryTerms.tokens(found.name).map(QueryTerms::strippingPossessive)
            if (tokens.all { it in subject.tokens }) continue
            return false
        }
        // …and the book's own table besides, because a general-purpose finder
        // misses the invented names, which are the ones readers ask about.
        for (word in Words.split(preceding)) {
            if (word.isCapitalised && word.token !in subject.tokens && word.token in knownNames) return false
        }
        return true
    }

    /**
     * A negation anywhere near the relation, which reverses what the sentence
     * says without changing a single one of the words the table matches on.
     */
    internal fun isNegated(words: List<Words.Word>, index: Int): Boolean {
        val lower = maxOf(0, index - negationReach)
        val upper = minOf(words.size - 1, index + negationReach)
        return (lower..upper).any { words[it].token in negations }
    }

    internal const val negationReach = 4
    internal val negations: Set<String> = setOf(
        "not", "no", "never", "nor", "neither", "n't", "isn't", "wasn't", "weren't",
        "hadn't", "hasn't", "didn't", "doesn't", "don't", "without", "unlike", "except",
    )
    internal val pronouns: Set<String> = setOf("his", "her", "their", "its", "my", "your", "our")
    internal val copulas: Set<String> = setOf("was", "is", "were", "are", "became")

    /** Adjectives a book puts between the owner and the relation. */
    internal val adjectives: Set<String> = setOf(
        "own", "elder", "older", "younger", "little", "big", "twin", "half",
        "only", "dear", "beloved", "poor", "eldest", "youngest", "step", "late",
        "adopted", "foster", "oldest",
    )
}
