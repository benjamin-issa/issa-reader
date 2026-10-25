package com.benjaminissa.issareader.ask

/**
 * Personal names from capitals, read the way a careful reader reads them.
 *
 * The Swift client asks `NLTagger(.nameType)` and keeps `.personalName`;
 * Android has no equivalent, so this is the stand-in, and the main way the two
 * clients can disagree about a book. What each caller needs from it decides
 * its shape:
 *
 * - **The index's name table** ([AskIndexStore] calls [NameFinder.names] per
 *   chapter): who to offer as a suggestion chip, which tokens of a question to
 *   promote to names, and — the one that matters — the earliest sighting the
 *   reading boundary hides a character behind. Over-finding costs a strange
 *   chip; missing a mention costs nothing worse than a later first sighting,
 *   which hides the character for longer, never shorter.
 * - **A question** ([QueryTerms]): which words are people. Every word found
 *   here is also probed by the spoiler gate, so over-finding refuses a
 *   question the reader can rephrase; and the gate reads capitals itself
 *   anyway, so under-finding loses nothing there.
 * - **One sentence** ([KinshipExtractor.onlyNames]): is anybody else in the
 *   sentence before "her brother"? Over-finding declines the fast path, and
 *   the model reads the sentences instead — the direction that table is tuned
 *   to fail in.
 *
 * So the rules lean towards finding a name only where the text itself says it
 * is one:
 *
 * 1. **A capital the position does not explain.** The first word of a
 *    sentence, of a line, or of quoted speech is capitalised for grammar, so it
 *    is never evidence on its own. A capital anywhere else is.
 * 2. **The text's own vote.** A word counts as a name only when it is
 *    capitalised mid-sentence more often than it is printed in lower case —
 *    "Dinah" in *Alice* is, "rabbit-hole" is not — and once it counts, every
 *    capitalised sighting is a mention, the sentence-opening ones included.
 *    That is what makes Alice's first mention the first line of Chapter I
 *    rather than the first "said Alice".
 * 3. **A person is named bare.** "said Alice", "Mr. Keimer", "Dinah, my
 *    dear": a capital after "the", "a", "his" or "Franklin's" is a thing with a
 *    title — "the Duchess", "the White Rabbit", "the Autobiography", "the
 *    Junto" — and does not vote. This is also where `NLTagger` draws the line:
 *    the Swift suites record it tagging neither "Duchess" nor "White Rabbit".
 * 4. **Closed-class words never.** Determiners, pronouns, auxiliaries,
 *    connectives, the question's own openers and fillers ([QueryTerms]'s
 *    lists), interjections, days and months, roman numerals, and a short list
 *    of capitals that are never people (languages, "God").
 * 5. **Places, by where they stand.** A word whose capitalised sightings mostly
 *    follow "in", "at", "from", "to", "of" and their like is a place, which is
 *    `NLTagger`'s `.placeName` and never a person. "Ryn had grown up on the
 *    streets of Ardmoor" therefore has one person in it, as the kinship table
 *    needs it to.
 * 6. **Shape.** Consecutive capitalised words are one name ("Mary Ann", "New
 *    England"), as `.joinNames` joins them; an honorific in front is not part of
 *    it ("Mr. Darcy"); a possessive or a contraction ends it ("Alice's",
 *    "Dinah'll"); a word in capitals counts only as a shouted spelling of a name
 *    the text already prints normally; and a heading line — short, unpunctuated
 *    and mostly capitals, or all capitals — contributes nothing, because a
 *    chapter title is not a sentence ("The Rabbit Sends in a Little Bill").
 *
 * What it cannot do that the tagger does: know that "Alice" is a name when the
 * text has only ever put it first in a sentence, or that "London" is a place
 * when it stands as a subject. The first only delays a first sighting; the
 * second is a place offered as a chip, which the spoiler probe treats like any
 * other word.
 */
object HeuristicNameTagger : NameTagger {
    override fun personalNames(text: String): List<TaggedName> {
        if (text.isEmpty()) return emptyList()
        val tokens = tokenise(text)
        if (tokens.isEmpty()) return emptyList()
        markInitials(tokens)
        val multiLine = tokens.any { it.lineIndex > 0 }
        val headings = if (multiLine) headingLines(tokens) else emptySet()
        val runs = runs(tokens, headings)
        val votes = vote(tokens, runs, headings)
        return names(runs, votes)
    }

    // Tokens

    private class Token(
        /** The word itself, possessive and contraction included. */
        val core: String,
        val coreStart: Int,
        /** Punctuation in front of the word: quotation marks, brackets. */
        val leading: String,
        /** Punctuation after it. */
        val trailing: String,
        /** Which line of the text the token is on. */
        val lineIndex: Int,
        /** Whether it is the first token on its line. */
        val opensLine: Boolean,
    ) {
        /** The word less a possessive or a contraction: "Alice" of "Alice's" and of "Dinah'll". */
        var name: String = core

        /** Whether a possessive or contraction ended the word, which ends a name there too. */
        var closed = false
        var isPossessive = false
        var key: String = ""
        var isCapitalised = false
        var isShouted = false
        var isInitial = false
        var endsSentence = false
    }

    /** A run of capitalised words that could be one name, and the token in front of it. */
    private class Run(val tokens: List<Token>, val before: Token?)

    private fun tokenise(text: String): List<Token> {
        val tokens = ArrayList<Token>()
        var line = 0
        var opensLine = true
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            if (isSwiftWhitespace(codePoint) || isDash(codePoint)) {
                if (isSwiftNewline(codePoint)) {
                    if (!(codePoint == '\n'.code && index > 0 && text[index - 1] == '\r')) line += 1
                    opensLine = true
                }
                index += Character.charCount(codePoint)
                continue
            }
            val start = index
            while (index < text.length) {
                val next = text.codePointAt(index)
                if (isSwiftWhitespace(next) || isDash(next)) break
                index += Character.charCount(next)
            }
            tokens.add(token(text, start, index, line, opensLine))
            opensLine = false
        }
        return tokens
    }

    private fun isDash(codePoint: Int): Boolean = codePoint == 0x2014 || codePoint == 0x2013

    private fun token(text: String, start: Int, end: Int, line: Int, opensLine: Boolean): Token {
        var coreStart = start
        while (coreStart < end) {
            val codePoint = text.codePointAt(coreStart)
            if (isSwiftLetter(codePoint) || isSwiftNumber(codePoint)) break
            coreStart += Character.charCount(codePoint)
        }
        var coreEnd = end
        while (coreEnd > coreStart) {
            val codePoint = text.codePointBefore(coreEnd)
            if (isSwiftLetter(codePoint) || isSwiftNumber(codePoint)) break
            coreEnd -= Character.charCount(codePoint)
        }
        val core = text.substring(coreStart, coreEnd)
        val token = Token(
            core = core, coreStart = coreStart, leading = text.substring(start, coreStart),
            trailing = text.substring(coreEnd, end), lineIndex = line, opensLine = opensLine,
        )
        if (core.isEmpty()) return token

        var name = core
        val lowered = straightened(core.lowercasedSwift())
        val contraction = CONTRACTIONS.firstOrNull { lowered.endsWith(it) && lowered.length > it.length }
        when {
            lowered.endsWith("'s") && lowered.length > 2 -> {
                name = core.dropLast(2)
                token.closed = true
                token.isPossessive = true
            }
            contraction != null -> {
                name = core.dropLast(contraction.length)
                token.closed = true
            }
            // "James'" — the trailing apostrophe is the possessive.
            lowered.endsWith("s") && (token.trailing.startsWith("'") || token.trailing.startsWith("’")) -> {
                token.closed = true
                token.isPossessive = true
            }
        }
        token.name = name
        token.key = straightened(NameFinder.Name.key(name))
        val codePoints = name.codePointList()
        val letters = codePoints.filter(::isSwiftLetter)
        val first = codePoints.firstOrNull()
        token.isCapitalised = first != null && isSwiftUppercase(first) && letters.size >= 2 && codePoints.none(::isSwiftNumber)
        token.isShouted = token.isCapitalised && letters.all(::isSwiftUppercase)
        return token
    }

    private fun straightened(text: String): String = text.replace('’', '\'')

    /**
     * Which tokens a sentence, a line or a quotation had to capitalise.
     *
     * A full stop after an honorific or an initial is not the end of a
     * sentence — "Mr. Darcy", "T. Rabbit" — for the reason the sentence
     * splitter merges them.
     */
    private fun markInitials(tokens: List<Token>) {
        for ((index, token) in tokens.withIndex()) {
            val closing = token.trailing.trimmingCharacters(CLOSERS)
            val terminal = closing.lastOrNull()?.let { it in SENTENCE_ENDS } == true
            val abbreviation = token.key in NameFinder.honorifics ||
                (token.core.length == 1 && token.core.firstCodePoint?.let(::isSwiftUppercase) == true)
            token.endsSentence = terminal && !(abbreviation && closing.startsWith("."))
            val previous = tokens.getOrNull(index - 1)
            token.isInitial = previous == null || token.opensLine || previous.endsSentence ||
                token.leading.any { it in OPENING_MARKS }
        }
    }

    /**
     * Lines that are headings rather than sentences: short, and either in
     * capitals throughout or unpunctuated and mostly capitalised. Only read on
     * a text of several lines — a question is one line, and "Tell me about
     * Dinah" is not a heading.
     */
    private fun headingLines(tokens: List<Token>): Set<Int> {
        val headings = HashSet<Int>()
        for ((line, onLine) in tokens.groupBy { it.lineIndex }) {
            val words = onLine.filter { word -> word.core.codePointList().any(::isSwiftLetter) }
            if (words.isEmpty() || words.size > HEADING_WORDS) continue
            val shouted = words.all { word -> word.core.codePointList().filter(::isSwiftLetter).all(::isSwiftUppercase) }
            val closing = onLine.last().trailing.trimmingCharacters(CLOSERS)
            val terminated = closing.lastOrNull()?.let { it in SENTENCE_ENDS } == true
            val capitalised = words.count { it.core.firstCodePoint?.let(::isSwiftUppercase) == true }
            if (shouted || (!terminated && capitalised * 2 >= words.size)) headings.add(line)
        }
        return headings
    }

    // Runs

    /** A capitalised word that could be part of a name at all. */
    private fun isEligible(token: Token): Boolean {
        if (!token.isCapitalised) return false
        val key = token.key
        if (key in excluded || key in NameFinder.honorifics) return false
        if (key.startsWith("i'")) return false
        if (token.isShouted && token.name.all { it in ROMAN_NUMERALS }) return false
        return true
    }

    private fun isHonorific(token: Token): Boolean = token.isCapitalised && token.key in NameFinder.honorifics

    /**
     * Consecutive eligible capitals on one line with nothing between them, an
     * honorific in front set aside, a possessive or a contraction ending them.
     */
    private fun runs(tokens: List<Token>, headings: Set<Int>): List<Run> {
        val runs = ArrayList<Run>()
        var current = ArrayList<Token>()
        var before: Token? = null

        fun close() {
            if (current.isNotEmpty()) runs.add(Run(current, before))
            current = ArrayList()
        }

        var index = 0
        while (index < tokens.size) {
            val token = tokens[index]
            if (token.lineIndex in headings) {
                close()
                index += 1
                continue
            }
            // An honorific in front of a name is not part of it, and its full
            // stop does not end a sentence.
            val next = tokens.getOrNull(index + 1)
            if (isHonorific(token) && next != null && next.lineIndex == token.lineIndex && isEligible(next)) {
                close()
                next.isInitial = false
                before = token
                current.add(next)
                if (next.closed || next.trailing.isNotEmpty()) close()
                index += 2
                continue
            }
            if (!isEligible(token)) {
                close()
                index += 1
                continue
            }
            val previous = current.lastOrNull()
            val continues = previous != null && !previous.closed && previous.trailing.isEmpty() &&
                token.leading.isEmpty() && !token.isInitial && previous.lineIndex == token.lineIndex
            if (!continues) {
                close()
                val prior = tokens.getOrNull(index - 1)
                before = if (prior != null && prior.lineIndex == token.lineIndex && prior.trailing.isEmpty() &&
                    token.leading.isEmpty()
                ) {
                    prior
                } else {
                    null
                }
            }
            current.add(token)
            if (token.closed || token.trailing.isNotEmpty()) close()
            index += 1
        }
        close()
        return runs
    }

    // The text's own vote

    private class Votes {
        val bare = HashMap<String, Int>()
        val lowerCase = HashMap<String, Int>()
        val afterLocative = HashMap<String, Int>()

        /** Every capitalised sighting, wherever it stands. */
        val capitalised = HashMap<String, Int>()

        fun isName(key: String): Boolean {
            val sightings = bare[key] ?: 0
            if (sightings == 0) return false
            if ((lowerCase[key] ?: 0) >= sightings) return false
            // A place, by where it stands: most of its capitalised sightings
            // follow a locative preposition.
            return (afterLocative[key] ?: 0) * 2 <= sightings
        }
    }

    private fun vote(tokens: List<Token>, runs: List<Run>, headings: Set<Int>): Votes {
        val votes = Votes()
        for (token in tokens) {
            if (token.lineIndex in headings || token.key.isEmpty()) continue
            val first = token.name.firstCodePoint ?: continue
            if (Character.isLowerCase(first)) votes.lowerCase.merge(token.key, 1, Int::plus)
            if (token.isCapitalised && !token.isShouted) votes.capitalised.merge(token.key, 1, Int::plus)
        }
        for (run in runs) {
            val before = run.before
            // "the Duchess", "Franklin's Autobiography": a thing with a title.
            val titled = before != null && (before.key in DETERMINERS || before.isPossessive)
            if (titled) continue
            val locative = before != null && before.key in LOCATIVES
            for (token in run.tokens) {
                if (token.isShouted || token.isInitial) continue
                votes.bare.merge(token.key, 1, Int::plus)
                if (locative) votes.afterLocative.merge(token.key, 1, Int::plus)
            }
        }
        return votes
    }

    // Names

    private fun names(runs: List<Run>, votes: Votes): List<TaggedName> {
        val found = ArrayList<TaggedName>()
        for (run in runs) {
            // A word in capitals is a name only as a shouted spelling of one
            // the text prints normally; anything else ends the run there.
            val words = ArrayList<Token>()
            for (token in run.tokens) {
                if (token.isShouted && !votes.isName(token.key)) {
                    emit(words, votes, found)
                    words.clear()
                    continue
                }
                words.add(token)
            }
            emit(words, votes, found)
        }
        return found
    }

    private fun emit(words: MutableList<Token>, votes: Votes, found: MutableList<TaggedName>) {
        // A sentence-opening word the text never uses as a name is capitalised
        // for grammar: "Poor Alice" is Alice. Unless a name follows it and the
        // text, having capitalised it more than once, never prints it in lower
        // case: "“Cheshire Puss,” she began" is one name, the way "Mary Ann"
        // is. A contraction is grammar whatever the count ("Didn't Alice").
        while (words.isNotEmpty() && words.first().isInitial && !votes.isName(words.first().key)) {
            val opener = words.first()
            val joined = words.size > 1 && votes.isName(words[1].key) &&
                (votes.lowerCase[opener.key] ?: 0) == 0 && (votes.capitalised[opener.key] ?: 0) >= 2 &&
                opener.core.none { it == '\'' || it == '’' }
            if (joined) break
            words.removeAt(0)
        }
        if (words.isEmpty() || words.size > MAXIMUM_NAME_WORDS) return
        if (words.none { votes.isName(it.key) }) return
        found.add(TaggedName(words.joinToString(" ") { it.name }, words.first().coreStart))
    }

    // Vocabulary

    private const val HEADING_WORDS = 12
    private const val MAXIMUM_NAME_WORDS = 4

    private val SENTENCE_ENDS = setOf('.', '!', '?', '…')
    private val OPENING_MARKS = setOf('"', '\'', '“', '‘', '«', '‹', '(', '[')
    private const val CLOSERS = "\"'”’)]}»›"
    private val ROMAN_NUMERALS = setOf('I', 'V', 'X', 'L', 'C', 'D', 'M')

    /** Contractions after a name: "Dinah'll", "Alice'd". The possessive is handled on its own. */
    private val CONTRACTIONS = listOf("'ll", "'d", "'re", "'ve", "'m")

    /** What stands before a thing with a title rather than before a person. */
    private val DETERMINERS: Set<String> = setOf(
        "the", "a", "an", "this", "that", "these", "those", "his", "her", "my", "your", "our", "their",
        "its", "whose", "every", "each", "some", "any", "no", "another", "such",
    )

    /** Prepositions a place stands after far more often than a person does. */
    private val LOCATIVES: Set<String> = setOf(
        "in", "at", "from", "to", "into", "of", "near", "across", "through", "towards", "toward",
        "beyond", "around", "within", "past", "onto", "upon", "outside", "inside", "via",
        "throughout", "unto",
    )

    /** Interjections, which dialogue capitalises after a comma as readily as at the start. */
    private val INTERJECTIONS: Set<String> = setOf(
        "oh", "ah", "o", "alas", "hush", "hello", "hallo", "goodbye", "farewell", "pray", "ay", "aye",
        "nay", "hurrah", "hurray", "bravo", "ugh", "ooh", "aha", "eh", "hm", "er", "nonsense", "ma'am",
        "thank", "thanks", "dear", "good",
    )

    /** Capitals that are never a person: languages, peoples, and the words of religion. */
    private val NEVER_PEOPLE: Set<String> = setOf(
        "english", "french", "latin", "greek", "german", "italian", "spanish", "dutch", "american",
        "americans", "british", "scottish", "irish", "welsh", "roman", "romans", "christian",
        "christians", "christianity", "christmas", "easter", "god", "gods", "heaven", "hell", "bible",
        "providence", "sabbath", "majesty", "highness", "lordship", "ladyship", "sire", "esq",
    )

    private val excluded: Set<String> by lazy {
        QueryTerms.sentenceOpeners + QueryTerms.stopWords + QuestionReader.leadingFillers +
            QueryTerms.questionImperatives + QueryTerms.capitalisedNonNames + INTERJECTIONS + NEVER_PEOPLE
    }
}
