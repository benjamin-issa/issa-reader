package com.benjaminissa.issareader.ask

/**
 * What a reader's question is actually asking the index for.
 *
 * Retrieval is the whole feature: a 4,096-token window cannot hold the book,
 * so the passages this picks are the entire evidence the model gets. Three
 * things had to be handled for ordinary questions to work at all.
 *
 * 1. **Names**, because "Who is the Cheshire Cat?" is a name lookup and a
 *    plain token match ranks every paragraph containing "cat".
 * 2. **Kinship**, because a novel almost never repeats the word in the
 *    question: a reader asks about a *cousin* and the text says *nephew*,
 *    *aunt*, *family*. Expanding the group is the difference between six
 *    relevant passages and none.
 * 3. **Recap**, because "what has happened so far" has no search terms in it
 *    at all and must take the last passages before the boundary instead.
 */
data class QueryTerms(
    /** The question after sanitising — what the model is shown, verbatim. */
    val question: String,
    /**
     * Personal names the question mentions, either found by [NameFinder] or
     * promoted because the book's own name table knows them.
     */
    val names: List<String>,
    /** Content words, stop list removed, names included. */
    val terms: List<String>,
    /**
     * Terms added by kinship expansion, kept apart so the ranker can reward a
     * passage for containing a *group*, not merely more words.
     */
    val kinshipGroups: List<List<String>>,
    /**
     * Every word in the question that looks like something the book would have
     * had to introduce: a found name, a name the index recognised, a
     * capitalised word that is not merely starting a sentence, or a lower-case
     * word the book's name table uses in a name.
     *
     * This is the input to the spoiler short-circuit, and it exists because of
     * a real answer the on-device model gave during development: asked "Who is
     * the Cheshire Cat?" from the end of Chapter I, it was handed six excerpts
     * containing no cat but Dinah, and answered "The Cheshire Cat is a talking
     * cat known for his mischievous behaviour" — from memory, ten chapters
     * ahead of the reader, in flat defiance of instructions that told it twice
     * not to. The model cannot be relied on to refuse; the app has to.
     */
    val nameCandidates: List<String> = emptyList(),
    /** What shape of question this is, which decides which retrieval runs. */
    val kind: QuestionKind,
) {
    /**
     * "What has happened so far?" and its relatives, which take the passages
     * before the boundary rather than a search.
     *
     * Derived rather than stored, so there is one answer to "is this a recap"
     * and the retriever's `when` cannot disagree with it.
     */
    val isRecap: Boolean get() = kind.isRecap

    /**
     * Whoever the question is about, when it is about anybody. Every retrieval
     * path except the recap requires this of a passage before considering it.
     */
    val subject: Subject? get() = kind.subject

    /** The question's own words first, then the kinship expansion, each once. */
    val searchTokens: List<String>
        get() {
            val seen = HashSet<String>()
            val ordered = ArrayList<String>()
            for (token in terms + kinshipGroups.flatten()) if (seen.add(token)) ordered.add(token)
            return ordered
        }

    companion object {
        /**
         * The longest question that is worth anything. Past this it is a pasted
         * paragraph, not a question, and every token in it dilutes the match.
         */
        const val maximumQuestionLength = 300

        /**
         * @param knownNames the book's own name table, bounded by the reading
         *   position. A token matching one is promoted to a name even when
         *   [NameFinder] did not find it — invented names ("Cheshire",
         *   "Bilbo") are exactly the ones a general-purpose tagger misses, and
         *   exactly the ones readers ask about.
         * @param bookNames the folded words of every name in the book's name
         *   table, *not* bounded — see [AskIndexStore.nameWords]. Read only to
         *   decide which of the question's lower-case words the spoiler probe
         *   checks; never a search term and never a promotion.
         */
        fun extract(
            question: String,
            knownNames: List<String> = emptyList(),
            bookNames: Set<String> = emptySet(),
        ): QueryTerms {
            val sanitised = sanitise(question)
            val known = knownNames.map { it.lowercasedSwift() }.toSet()

            val names = taggedNames(sanitised).toMutableList()
            val terms = ArrayList<String>()
            for (raw in tokens(sanitised)) {
                // The possessive is stripped *here* rather than inside `tokens`,
                // which the FTS pattern tests depend on. "Ryn's" has to become
                // the name `ryn`: left alone it is neither a known name nor a
                // term the co-occurrence bonus can see, and SQLite's tokeniser
                // reads it as `ryn OR s` — which is how "What is the name of
                // Ryn's brother?" came back with a pool that never contained
                // "Her brother, Dask".
                val token = strippingPossessive(raw)
                // Before the promotion below, not after it. Gutenberg's own
                // header page prints "**Author**: Benjamin Franklin", so
                // `author` is in the book's name table — and the promotion
                // would make it a name the FTS pattern requires. See `bookRoles`.
                if (isBookRole(token)) continue
                if (token in known || known.any { it.startsWith("$token ") }) {
                    if (names.none { it.lowercasedSwift() == token }) names.add(token)
                    terms.add(token)
                    continue
                }
                if (token in stopWords || token.graphemeCount() <= 1) continue
                terms.add(token)
            }
            // A found multi-word name contributes its parts as search tokens;
            // FTS5 indexes words, not phrases.
            for (name in names) {
                for (part in tokens(name).map(::strippingPossessive)) {
                    if (part !in terms && part.graphemeCount() > 1) terms.add(part)
                }
            }

            // Classified from the names already found, rather than running the
            // name finder a second time.
            val kind = QuestionReader.kind(
                sanitised,
                Vocabulary(
                    known = known,
                    tagged = names.flatMap { name -> tokens(name).map(::strippingPossessive) }.toSet(),
                ),
            )
            return QueryTerms(
                question = sanitised,
                names = names,
                terms = terms,
                kinshipGroups = Kinship.groups(terms),
                // The whole question, not the clause the classifier decided on.
                // The gate read only the leading clause for a while, on the
                // ground that retrieval never looks at an aside — but the
                // answer side exempted every word of the question on the ground
                // that this side had ruled on it, so "Who is Alice? Does she
                // ever meet the Cheshire Cat?" was answered "Yes, she later
                // meets the Cheshire Cat." with neither guard having looked at
                // the name (R-04).
                nameCandidates = nameCandidates(sanitised, names, bookNames),
                kind = kind,
            )
        }

        /**
         * "Ryn's" → "Ryn", everything else untouched.
         *
         * Applied to tokens rather than inside [tokens] on purpose: that
         * function's output is what the FTS pattern is built from in the older
         * call sites and in the tests, and changing it would move offsets
         * nobody asked to move.
         */
        fun strippingPossessive(token: String): String {
            if (token.graphemeCount() <= 2 || !token.endsWith("'s")) return token
            return token.dropLast(2)
        }

        /**
         * Words the book would have had to introduce for the question to be
         * answerable at all.
         *
         * Capitalisation rather than the name finder alone, because the names
         * readers ask about are the invented ones — "Cheshire", "Bilbo",
         * "Meursault" — and a general-purpose tagger knows none of them.
         *
         * Every sentence's first word is skipped only when it is a word a
         * question opens with anyway — "Who", "Did", "Tell", "Where'd", "Hey" —
         * and checked like any other otherwise. It was skipped unconditionally,
         * on the ground that every question starts with a capital, while the
         * answer side exempted every word the question contained on the ground
         * that this side had ruled on it. Together that was a hole exactly the
         * shape of a bare-name question: "Cheshire Cat?" at the end of Chapter
         * I probed only `cat` (met: Dinah), and an answer describing the Cat
         * was shown because its name was in the question.
         *
         * **Every sentence, and lower case too** (R-04). The answer side no
         * longer exempts anything, but this side is still the one that keeps
         * the model from being asked at all, so it reads the whole question: a
         * name in a second sentence is as much a name as one in the first, and
         * "who is the cheshire cat?" names the Cat whether or not the reader
         * reached for the shift key. A lower-case word counts when the book's
         * own name table — the whole book's, [bookNames] — has it as part of a
         * name: that is the signal that survives an invented name, and the
         * probe then decides it against what has been read.
         *
         * Some ordinary words will be caught by this ("Is Alice British?"), and
         * the cost of that is a "the story hasn't revealed that yet" for a
         * question the model might have answered. That is the right way round:
         * a wrong refusal is an annoyance the reader can rephrase past, and a
         * wrong answer about a character forty pages ahead is the thing this
         * feature promised not to do.
         *
         * @param question the whole question.
         * @param names found over the whole question, filtered to the tokens it
         *   actually contains.
         */
        fun nameCandidates(question: String, names: List<String>, bookNames: Set<String> = emptySet()): List<String> {
            val present = tokens(question).map(::strippingPossessive).toSet()
            val candidates = names.flatMap { name -> tokens(name).map(::strippingPossessive) }
                .filter { it in present }
                .toMutableSet()
            candidates.addAll(present.filter { it in bookNames && it !in stopWords })
            for (sentence in SentenceSplitter.ranges(question)) {
                var opening = true
                for (word in question.substring(sentence.location, sentence.end).splitOnWhitespace()) {
                    val bare = word.trimmingNonLetters()
                    // "Hey, who is…", "Okay so what…": the classifier drops these
                    // from the front of the question, and so does the gate — the
                    // word after them is the one the sentence had to capitalise.
                    if (isFiller(bare)) continue
                    val wasOpening = opening
                    opening = false
                    val initial = bare.firstCodePoint ?: continue
                    if (!isSwiftUppercase(initial) || bare.graphemeCount() <= 2) continue
                    if (wasOpening && opensAQuestion(bare)) continue
                    if (bare.lowercasedSwift() in capitalisedNonNames) continue
                    // Possessive-stripped, or "Ryn's" is checked against the
                    // index as `ryn's` — a word no book contains as one token,
                    // so the spoiler guard tests something that is not the name.
                    candidates.addAll(tokens(bare).map(::strippingPossessive))
                }
            }
            // `bookRoles` and the fillers filtered last rather than in the
            // loop, because the seed set above comes from the name finder as
            // well as from the loop: a question that capitalises "the
            // Narrator" must not be refused as naming somebody the book has
            // not introduced, and a tagger can take the "Hmm" of "Hmm, who is
            // Dinah?" for a person.
            return candidates.filter { it.graphemeCount() > 2 && !isBookRole(it) && !isFiller(it) }.sorted()
        }

        /**
         * Whether this word is the hesitation a reader types before a question
         * — [QuestionReader.leadingFillers], the classifier's own list. Never a
         * name, wherever it stands: "Hmm" was probed as one, found unmet, and
         * "Hmm, who is Dinah?" was refused without the model being asked (R-15).
         */
        internal fun isFiller(word: String): Boolean = word.lowercasedSwift() in QuestionReader.leadingFillers

        /**
         * Words a sentence capitalises for grammar rather than for a person.
         *
         * The contrast with [capitalisedNonNames] below is the whole design.
         * That list is exempt *everywhere* in an answer, so every word on it is
         * a word the book can never be caught spoiling, and it stays short.
         * This one is exempt only where a sentence had to capitalise the word
         * anyway — the first position — so it can afford to be long: a word
         * here is still checked in every other position it appears in.
         *
         * Closed-class only. Determiners, pronouns, auxiliaries, connectives
         * and the adverbs that open sentences; nothing that names or describes.
         * That is the test for admitting a word, and it is why these are
         * **deliberately absent**: `will`, `may`, `mark`, `grace`, `rose`,
         * `hope`, `faith`, `bill`, `frank`, `jack`, `art`, `dawn`, `june`,
         * `pat`, `sue`, `victor`. Every one is a name somebody has, and
         * membership is an exemption for ever — the cost of leaving them off is
         * one wrong refusal that the reader can rephrase past. (`march` and
         * `june` are exempt everywhere through [capitalisedNonNames], which is
         * a judgement made there, not here.)
         *
         * A word not on this list that opens a sentence is a candidate, and
         * [AskIndexStore.unmetWords] then decides it per book: over-catching
         * only costs anything when the over-caught word is absent from the part
         * the reader has read. "Rome" is in *Alice* Chapter II — "London is the
         * capital of Paris, and Paris is the capital of Rome" — so it is
         * cleared from there onwards and refused before it, which is exactly
         * right.
         */
        val sentenceOpeners: Set<String> = setOf(
            // Determiners and quantifiers.
            "a", "an", "the", "this", "that", "these", "those", "each", "every",
            "some", "any", "no", "all", "both", "either", "neither", "another",
            "such", "much", "many", "few", "fewer", "several", "most", "more",
            "less", "least", "enough", "other", "half",
            // Pronouns.
            "i", "you", "he", "she", "it", "we", "they", "me", "him", "us", "them",
            "my", "your", "his", "her", "its", "our", "their", "mine", "yours",
            "hers", "ours", "theirs", "myself", "yourself", "himself", "herself",
            "itself", "ourselves", "themselves", "who", "whom", "whose", "which",
            "what", "whatever", "whoever", "whichever", "someone", "somebody",
            "something", "anyone", "anybody", "anything", "everyone", "everybody",
            "everything", "nobody", "nothing", "none", "one", "ones",
            // Auxiliaries and copulas.
            "am", "is", "are", "was", "were", "being", "been", "be", "do", "does",
            "did", "doing", "done", "have", "has", "had", "having", "can", "could",
            "shall", "should", "would", "must", "might", "ought", "cannot",
            // Connectives.
            "and", "but", "or", "nor", "for", "yet", "so", "because", "since",
            "although", "though", "while", "whilst", "whereas", "unless", "until",
            "till", "if", "then", "than", "as", "when", "whenever", "where",
            "wherever", "after", "before", "once", "whether", "however",
            "therefore", "thus", "hence", "moreover", "furthermore",
            "nevertheless", "nonetheless", "besides", "meanwhile", "otherwise",
            "instead", "also",
            // Prepositions and particles that open a clause.
            "at", "by", "in", "on", "to", "of", "with", "without", "within",
            "from", "into", "onto", "upon", "over", "under", "above", "below",
            "through", "across", "along", "around", "behind", "beyond", "during",
            "against", "between", "among", "beside", "toward", "towards", "off",
            "out", "up", "down", "back", "away", "despite", "throughout", "beneath",
            "inside", "outside", "unlike",
            // Adverbs that open sentences.
            "not", "never", "always", "often", "sometimes", "soon", "now", "later",
            "again", "already", "almost", "nearly", "just", "only", "even",
            "quite", "rather", "very", "really", "perhaps", "maybe", "probably",
            "possibly", "certainly", "surely", "indeed", "actually", "finally",
            "eventually", "suddenly", "immediately", "still", "here", "there",
            "everywhere", "somewhere", "anywhere", "nowhere", "together", "yes",
            "well", "why", "how", "let", "there's", "it's", "that's", "here's",
        )

        /**
         * Whether a question's first word is one it would capitalise anyway.
         *
         * [sentenceOpeners] — the closed-class words the answer side already
         * exempts at the start of a sentence — and the imperatives a reader
         * opens a request with, which would otherwise be probed as names and
         * refuse "Describe the garden." in any book that never says "describe".
         *
         * Contractions are read through their stem, so "Who's" is "who",
         * "What'd" and "Where'd" are "what" and "where", "Who're" is "who" —
         * and any negated auxiliary ("Aren't", "Didn't", "Won't") is one,
         * because no name ends in n't. Only the possessive was stripped, so
         * every other contraction was probed as a name, found nowhere in the
         * book (`unicode61` reads it as "what d"), and the question refused
         * (R-15).
         */
        internal fun opensAQuestion(word: String): Boolean {
            val token = tokens(word).firstOrNull() ?: return false
            if (token.endsWith("n't")) return true
            val stem = withoutContraction(token)
            return token in sentenceOpeners || stem in sentenceOpeners || stem in questionImperatives
        }

        /**
         * The word a contraction was made from: "what'd" → "what", "who're" →
         * "who", "ryn's" → "ryn". Anything else untouched.
         */
        internal fun withoutContraction(token: String): String {
            for (suffix in contractionSuffixes) {
                if (token.endsWith(suffix) && token.graphemeCount() > suffix.length) return token.dropLast(suffix.length)
            }
            return token
        }

        internal val contractionSuffixes = listOf("'s", "'d", "'re", "'ve", "'ll", "'m")

        /**
         * The verbs a request to the book opens with. Imperatives only: nothing
         * here could be anybody's name, which is the bar [sentenceOpeners] sets
         * too.
         */
        internal val questionImperatives: Set<String> = setOf(
            "tell", "describe", "explain", "summarise", "summarize", "recap",
            "remind", "give", "list", "show", "compare", "define", "identify",
            "outline", "recount", "say", "talk", "remember", "recall", "help",
            "name", "find", "please", "whats", "whos", "wheres", "hows", "whys", "wait",
            "okay",
        )

        /**
         * Words that are capitalised in ordinary prose without naming anybody.
         * Short on purpose: a long list here is a long list of things a book
         * can spoil.
         */
        internal val capitalisedNonNames: Set<String> = setOf(
            "chapter", "section", "part", "book", "volume", "page",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "january", "february", "march", "april", "june", "july",
            "august", "september", "october", "november", "december",
        )

        /**
         * Words that name whoever *made* the book rather than anybody in it.
         *
         * **Its own list, and not a few more entries in either of the two
         * above**, because those two answer different questions. [stopWords]
         * asks "does this word carry retrieval signal?" and is deliberately
         * short — `author` carries a great deal of signal, which is precisely
         * the problem, and [stopWords] is consulted when building `terms` but
         * not when building `nameCandidates`, which is the other half of the
         * fix. [capitalisedNonNames] asks "did the sentence capitalise this for
         * grammar?"; its members are exempt *everywhere in an answer*, so every
         * word on it is a word the book can never be caught spoiling, and these
         * words are lowercase in prose and would buy nothing there. This list
         * answers a third question — "could the book have introduced this as a
         * person?" — and the answer has to be no in three places at once: the
         * [Subject] every retrieval path requires of every passage, the tokens
         * the FTS pattern is built from, and the spoiler probe.
         *
         * **The bug**, measured on *Autobiography of Benjamin Franklin*
         * (Gutenberg #20203). "What happened to the author's son?" made
         * `author` the possessive owner, so `Subject.tokens` was `["author"]`
         * and every passage had to contain the word — which in a Gutenberg
         * non-fiction book means the boilerplate ("**Author**: Benjamin
         * Franklin"), the editor's introduction and every "author of *X*". One
         * excerpt came back, about Dr Mandeville and Isaac Newton, and the
         * model answered "The author's son died." Dropping the word leaves
         * `["happened", "son"]` and the kinship group, and the answer became
         * "The author's son died of the small-pox." — right, and *longer*, with
         * no prompt change at all. "Who is the author's father?" went from
         * "Benjamin Franklin" to "Josiah Franklin" the same way.
         *
         * `editor` and `translator` are here for the same reason and not for a
         * measured one: Gutenberg prints "Editor: Frank Woodworth Pine" in the
         * header of the very book above, and a question about the editor fails
         * identically. `narrator` is the fiction spelling of the same mistake.
         *
         * The cost is a book that is genuinely *about* an author: "Who is the
         * author of *Frankenstein*?" loses one token from its query and keeps
         * every other word. The alternative is the failure above on every
         * memoir.
         */
        internal val bookRoles: Set<String> = setOf(
            "author", "authors", "writer", "writers", "narrator", "narrators",
            "poet", "poets", "essayist", "essayists",
            "editor", "editors", "translator", "translators",
        )

        /**
         * Whether this token names the book's maker rather than a person in it.
         *
         * Possessive-stripped, because the reported question was "What
         * happened to the author's son?" and the word arrives as `author's`
         * from a reader who wrote it that way.
         */
        internal fun isBookRole(token: String): Boolean = strippingPossessive(token.lowercasedSwift()) in bookRoles

        /**
         * Collapses whitespace and clamps the length. Nothing is escaped here —
         * the FTS pattern is built by [FtsQuery], which is the only thing that
         * can be trusted to quote for SQLite's tokeniser.
         */
        fun sanitise(question: String): String {
            val collapsed = buildString {
                var start = -1
                var index = 0
                fun flush(end: Int) {
                    if (start < 0) return
                    if (isNotEmpty()) append(' ')
                    append(question, start, end)
                    start = -1
                }
                while (index < question.length) {
                    val codePoint = question.codePointAt(index)
                    if (isWhitespaceOrNewline(codePoint)) flush(index) else if (start < 0) start = index
                    index += Character.charCount(codePoint)
                }
                flush(question.length)
            }
            if (collapsed.graphemeCount() <= maximumQuestionLength) return collapsed
            return collapsed.graphemePrefix(maximumQuestionLength).trimmingWhitespaces()
        }

        /**
         * Lowercased word tokens, apostrophes and hyphens kept inside a word.
         *
         * A curly apostrophe is folded to a straight one, because the book's
         * text carries whichever its typesetter used and the two must tokenise
         * the same — this is the difference between "Alice's" matching and
         * matching nothing.
         */
        fun tokens(text: String): List<String> {
            val out = ArrayList<String>()
            val current = StringBuilder()
            val folded = text.foldingDiacritics()
            fun finish() {
                val token = current.toString().trimmingCharacters("'")
                if (token.isNotEmpty()) out.add(token)
                current.setLength(0)
            }
            var index = 0
            while (index < folded.length) {
                val codePoint = folded.codePointAt(index)
                index += Character.charCount(codePoint)
                if (isSwiftLetter(codePoint) || isSwiftNumber(codePoint)) {
                    // The lowercase of one character is not always one
                    // character ("İ" is two), so append the string.
                    current.append(String(Character.toChars(codePoint)).lowercasedSwift())
                } else if (codePoint == '\''.code || codePoint == 0x2019 || codePoint == '-'.code) {
                    // Kept only *inside* a word, so a leading quotation mark
                    // does not open a token that FTS5 then reads as a phrase.
                    if (current.isNotEmpty()) current.append('\'')
                } else if (current.isNotEmpty()) {
                    finish()
                }
            }
            if (current.isNotEmpty()) finish()
            return out
        }

        internal fun taggedNames(text: String): List<String> = NameFinder.names(text, spineIndex = 0).map { it.name }

        /** Questions that are asking for the story so far rather than for a fact. */
        internal fun isRecapQuestion(question: String): Boolean {
            val lowered = question.lowercasedSwift()
            return recapPatterns.any { lowered.contains(it) }
        }

        internal val recapPatterns: List<String> = listOf(
            "what has happened", "what's happened", "what happened so far",
            "recap", "summarise", "summarize", "summary",
            "catch me up", "remind me what", "where was i", "where am i",
            "what have i read", "so far in the story", "what's the story so far",
            "story so far",
        )

        /**
         * The interrogatives that say the answer is a person: search tokens for
         * the ranker, but never the only thing a passage is required to contain
         * beside its subject. See [AskRetriever.optionalTerms].
         */
        internal val personWords: Set<String> = setOf("who", "whom", "whose")

        /**
         * Words that carry no retrieval signal. Deliberately short: an
         * aggressive stop list throws away "who", which is the one word that
         * says the answer is a person, and the ranker wants that signal.
         */
        internal val stopWords: Set<String> = setOf(
            "a", "an", "the", "and", "or", "but", "if", "then", "than", "that",
            "this", "these", "those", "is", "are", "was", "were", "be", "been",
            "being", "am", "do", "does", "did", "doing", "have", "has", "had",
            "having", "of", "in", "on", "at", "to", "for", "with", "from", "by",
            "about", "into", "over", "after", "before", "up", "down", "out",
            "it", "its", "he", "she", "they", "them", "his", "her", "their",
            "i", "me", "my", "we", "us", "our", "you", "your",
            "what", "when", "where", "why", "how", "which", "there", "here",
            "so", "far", "just", "very", "can", "could", "would", "should",
            "will", "shall", "may", "might", "must", "not", "no", "yes",
            "please", "tell", "again", "any", "some", "all",
        )
    }
}

/**
 * Family words, grouped so a question about one reaches passages about the
 * others.
 *
 * The point is recall, not synonymy: nobody claims a cousin is an aunt. A novel
 * introduces a relative once and then refers to them by name, so the only
 * paragraphs that will ever contain "cousin" are the two that introduce them —
 * and a question asked forty pages later matches neither without this.
 */
object Kinship {
    /**
     * One group per relationship a reader asks about. A term in any group pulls
     * in the whole group.
     *
     * **The only place a family word is written down.** [KinRelation.all]
     * reads its relations out of these groups rather than keeping a second
     * list, because there were two lists and they disagreed in both directions.
     */
    val all: List<List<String>> = listOf(
        listOf(
            "cousin", "cousins", "relative", "relatives", "relation", "relations",
            "family", "families", "kin",
        ),
        listOf("brother", "brothers", "sister", "sisters", "sibling", "siblings"),
        listOf(
            "mother", "mothers", "mum", "mama", "mamma",
            "father", "fathers", "papa", "dad", "parent", "parents",
        ),
        listOf("aunt", "aunts", "uncle", "uncles", "niece", "nieces", "nephew", "nephews"),
        listOf(
            "husband", "husbands", "wife", "wives", "spouse", "spouses",
            "widow", "widows", "widower", "widowers", "married", "marriage",
        ),
        listOf("son", "sons", "daughter", "daughters", "child", "children", "baby", "babies"),
        listOf(
            "grandmother", "grandmothers", "grandma", "grandfather", "grandfathers", "grandpa",
            "grandparent", "grandparents", "grandson", "grandsons",
            "granddaughter", "granddaughters", "grandchild", "grandchildren",
        ),
        listOf("friend", "friends", "friendship", "companion", "companions"),
    )

    /** Every group at least one of these terms belongs to. */
    fun groups(terms: List<String>): List<List<String>> {
        val lowered = terms.map { it.lowercasedSwift() }.toSet()
        return all.filter { group -> group.any { it in lowered } }
    }
}
