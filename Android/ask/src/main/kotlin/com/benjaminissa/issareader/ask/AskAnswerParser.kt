package com.benjaminissa.issareader.ask

/** One excerpt an answer rests on, as the sheet shows it. */
data class AskSource(
    /** The ordinal the model cited, one-based, as it appeared in the prompt. */
    val ordinal: Int,
    /** Real chapter offsets, so tapping it can open the book there. */
    val passage: Passage,
    /**
     * Where this excerpt came in the ranker's own sort, lowest first — the
     * [PassageRanker.Ranked.priority] the prompt was packed from.
     *
     * Nullable because a tool's excerpts were never scored: they are in the
     * prompt because the model asked for them, and there is no rank to report.
     * Those sort last rather than first, so an unranked excerpt never
     * displaces one the retrieval chose.
     */
    val priority: Int? = null,
) {
    val id: Int get() = ordinal

    companion object {
        /**
         * The strongest [limit] of these, in the order the model cited them.
         *
         * Two orders at once, and both matter. *Which* to keep is the ranker's
         * question — a recap hands the model fifteen excerpts in book order and
         * the row was showing the first three, which is the opening of what the
         * reader has read rather than the evidence the answer leans on. *What
         * order to show them in* is the answer's — the citations arrive in the
         * order the prose used them, and re-sorting the chips by rank would put
         * the third sentence's excerpt in front of the first's.
         *
         * Ties break on the ordinal so the result is stable; an excerpt with no
         * priority sorts behind every excerpt that has one.
         */
        fun best(sources: List<AskSource>, limit: Int): List<AskSource> {
            if (sources.size <= limit) return sources
            val strongest = sources.sortedWith { left, right ->
                val leftRank = left.priority
                val rightRank = right.priority
                when {
                    leftRank != null && rightRank != null ->
                        if (leftRank == rightRank) left.ordinal.compareTo(right.ordinal) else leftRank.compareTo(rightRank)
                    leftRank == null && rightRank != null -> 1
                    leftRank != null && rightRank == null -> -1
                    else -> left.ordinal.compareTo(right.ordinal)
                }
            }.take(limit).map { it.ordinal }.toSet()
            return sources.filter { it.ordinal in strongest }
        }
    }
}

/** A finished answer, split into the parts the UI actually shows. */
data class AskAnswer(
    /** The prose, with the `Sources:` line removed. */
    val text: String,
    /**
     * The ordinals the model cited, one-based, as they appeared in the prompt.
     *
     * Kept beside [sources] rather than replaced by it: this is the model's raw
     * claim and [sources] is what survived validation, so "cited 9, was handed
     * six" is a state a test can assert on rather than a silent drop.
     */
    val citations: List<Int>,
    /**
     * Whether the model said the story has not revealed this yet. A state, not
     * an error: it is the correct answer to a question about a spoiler, and it
     * is what the whole boundary exists to make possible.
     */
    val notYetRevealed: Boolean,
    val origin: Origin = Origin.MODEL,
    /**
     * The excerpts the citations actually name, in the order they were cited.
     *
     * Resolved once, where the numbering is still in scope. An answer nothing
     * composed — the sentinel, and the vetting pass's refusal — carries none,
     * because there is nothing to show proof of.
     */
    val sources: List<AskSource> = emptyList(),
) {
    /**
     * Who composed the sentence, so the sheet can say so without guessing.
     *
     * Three answers reach the reader and only one of them was written by a
     * model. A disclosure under all three put an AI label under a sentence
     * lifted verbatim out of the book and under a hardcoded refusal no model
     * was ever asked for.
     */
    enum class Origin {
        /** A language model composed this. */
        MODEL,

        /**
         * The book's own words: [KinshipExtractor] assembles the sentence from
         * a paragraph the reader has already read, and no model is called at
         * all.
         */
        BOOK,

        /**
         * Nothing was answered — the "not yet" sentinel, whether it came from
         * the model or was substituted over a generated answer by the vetting
         * pass.
         */
        WITHHELD,
    }
}

/**
 * Reads the model's plain-string answer.
 *
 * The output conventions are two lines of instruction rather than a schema,
 * because guided generation runs stricter safety checks on Apple's side and a
 * novel's ordinary content trips them constantly; the Android model reads the
 * same instructions. So the structure is a convention the model mostly keeps,
 * and this has to cope with it not keeping it.
 */
object AskAnswerParser {
    /**
     * The exact sentence the instructions ask for when the excerpts do not
     * contain the answer. Compared loosely below, because a small model
     * paraphrases punctuation.
     */
    const val notYetSentinel = "The story hasn't revealed that yet."

    fun parse(raw: String): AskAnswer {
        val (body, citations) = splitSources(raw)
        val trimmed = body.trimmingWhitespaceAndNewlines()
        val prose = withoutSentinel(trimmed)
        if (prose.isNotEmpty() || trimmed.isEmpty()) {
            // Prose, with any sentinel sentence taken out of it. The sentinel
            // followed by an answer is the hedge a small model writes — "The
            // story hasn't revealed that yet. However, …" — and the answer
            // after it is an answer like any other: it goes to the vetting
            // pass, which a refusal skips, and is shown only if every name in
            // it is one the reader has met.
            return AskAnswer(text = prose, citations = citations, notYetRevealed = false)
        }
        // Nothing but the sentinel. A refusal even when a model typed it, so
        // there is no generated prose under it to disclose, and no citations:
        // excerpts under "the story hasn't revealed that yet" would be proof
        // offered of an absence.
        return AskAnswer(text = notYetSentinel, citations = emptyList(), notYetRevealed = true, origin = AskAnswer.Origin.WITHHELD)
    }

    /**
     * The text with every sentence that is exactly the sentinel removed.
     *
     * Sentence by sentence, because the sentinel is a whole sentence and the
     * hedge puts it either side of an answer. A sentence that merely
     * *contains* it — "The story hasn't revealed that yet, but Alice meets the
     * Duchess." — is prose and is kept whole: that is an answer, and it is what
     * the vetting pass is for.
     */
    internal fun withoutSentinel(text: String): String {
        if (text.isEmpty()) return text
        val sentences = SentenceSplitter.ranges(text).map { text.substring(it.location, it.end) }
        val kept = sentences.filter { !isNotYet(it) }
        if (kept.size == sentences.size) return text
        return kept.joinToString("").trimmingWhitespaceAndNewlines()
    }

    // Resolving citations

    /**
     * The excerpts an answer's citations actually name.
     *
     * In the order the model cited them, deduplicated, and with any ordinal
     * naming nothing dropped. A small model handed six excerpts cites `[9]`
     * often enough that this cannot be an assertion.
     *
     * @param priorities each excerpt's place in the ranker's sort, by passage
     *   rather than by ordinal. An excerpt missing from the map carries no
     *   priority, which is what a tool excerpt is.
     */
    fun sources(citations: List<Int>, shown: Map<Int, Passage>, priorities: Map<Passage, Int> = emptyMap()): List<AskSource> {
        val seen = HashSet<Int>()
        return citations.mapNotNull { ordinal ->
            if (!seen.add(ordinal)) return@mapNotNull null
            val passage = shown[ordinal] ?: return@mapNotNull null
            AskSource(ordinal, passage, priorities[passage])
        }
    }

    /**
     * The same answer with its citations turned into excerpts the sheet can
     * show. Separate from [parse] because the numbering is not known there.
     */
    fun resolving(answer: AskAnswer, shown: Map<Int, Passage>, priorities: Map<Passage, Int> = emptyMap()): AskAnswer =
        answer.copy(sources = sources(answer.citations, shown, priorities))

    /**
     * What may safely be shown while the answer is still arriving.
     *
     * A stream ends with "Sources: 1, 3" and passes through every prefix of it
     * on the way — "S", "Sour", "Sources: 1," — so showing the raw partial
     * flickers a half-typed footer under the reader's answer. Anything from a
     * line that *could* become the sources line is withheld until it is known
     * not to be one.
     */
    fun visible(partial: String): String {
        var text = splitSources(partial).first
        // A trailing fragment that is still a prefix of "Sources:" is held
        // back; once it is longer than the label and does not match, it is
        // ordinary prose and shown.
        val lastBreak = text.lastIndexOf('\n')
        if (lastBreak >= 0) {
            if (opensFooter(text.substring(lastBreak + 1))) text = text.substring(0, lastBreak)
        } else if (opensFooter(text)) {
            return ""
        }
        // The same hold for a footer begun on the prose's own line, after its
        // last full stop — where Apple's newer model puts it.
        val sentenceEnd = lastSentenceEnd(text)
        if (sentenceEnd != null && opensFooter(text.substring(sentenceEnd))) text = text.substring(0, sentenceEnd)
        return text.trimmingWhitespaceAndNewlines()
    }

    // Pieces

    internal const val sourcesLabel = "Sources:"

    internal fun isPrefixOfSourcesLabel(candidate: String): Boolean {
        val trimmed = candidate.trimmingWhitespaces()
        if (trimmed.isEmpty()) return false
        return sourcesLabel.lowercasedSwift().startsWith(trimmed.lowercasedSwift())
    }

    /**
     * Whether a fragment could be a footer being typed — either still shorter
     * than the label, or already past it. The second half is what a prefix
     * test alone misses: by "Sources: 1 a" the fragment has stopped being a
     * prefix of the label, and the half-typed footer flashed under the answer.
     */
    internal fun opensFooter(candidate: String): Boolean {
        val trimmed = candidate.trimmingWhitespaces()
        if (trimmed.isEmpty()) return false
        val label = sourcesLabel.lowercasedSwift()
        val lowered = trimmed.lowercasedSwift()
        return label.startsWith(lowered) || lowered.startsWith(label)
    }

    /**
     * The characters a sentence can end on, for telling a footer written after
     * the prose from the word "sources" written inside it. Not `:` or `;`,
     * which end a clause rather than a sentence — "he named the following:
     * Sources: 1" has to stay prose.
     */
    internal val sentenceEnds: Set<Int> = setOf(0x2E, 0x21, 0x3F, 0x2026)

    /** Whether this text ends a sentence, looking past whatever quotes or brackets close after the full stop. */
    internal fun endsSentence(text: String): Boolean {
        var end = text.length
        while (end > 0 && SentenceSplitter.isSkippable(text[end - 1].code)) end -= 1
        if (end == 0) return false
        return text[end - 1].code in sentenceEnds
    }

    /** The index just past the last sentence end, or null when there is none. */
    internal fun lastSentenceEnd(text: String): Int? {
        var index = text.length
        while (index > 0) {
            val previous = index - 1
            if (isSwiftWhitespace(text[previous].code) && endsSentence(text.substring(0, previous))) return index
            index = previous
        }
        return null
    }

    /**
     * The words that may stand among the ordinals in a footer. "none" because
     * a model writes "Sources: none" under a refusal, and a footer the parser
     * did not recognise stayed in the text as prose.
     */
    internal val citationWords: Set<String> = setOf("and", "section", "sections", "none")

    /**
     * …and the ones that introduce a chapter rather than a citation, so the
     * number after them is not an ordinal. One list, read by both
     * [isCitationTail] and [ordinals].
     */
    internal val chapterWords: Set<String> = setOf("section", "sections")

    /** Whether what follows the label reads as citations and nothing else. */
    internal fun isCitationTail(tail: String): Boolean {
        val words = splitWords(tail.lowercasedSwift())
        return words.all { word -> word.codePointList().all(::isSwiftNumber) || word in citationWords }
    }

    private fun splitWords(text: String): List<String> {
        val words = ArrayList<String>()
        val current = StringBuilder()
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            index += Character.charCount(codePoint)
            if (isSwiftLetter(codePoint) || isSwiftNumber(codePoint)) {
                current.appendCodePoint(codePoint)
            } else if (current.isNotEmpty()) {
                words.add(current.toString())
                current.setLength(0)
            }
        }
        if (current.isNotEmpty()) words.add(current.toString())
        return words
    }

    internal fun isBlank(text: String): Boolean = text.trimmingWhitespaces().isEmpty()

    /** A footer inside one line: the prose before it, and what it names. */
    internal data class Footer(val beforeLabel: String, val citations: List<Int>)

    /**
     * A line carries a footer when the label begins it — the shape the
     * instructions ask for — or when the label follows the end of a sentence.
     * Either way nothing but citations may follow, so "the sources: he said"
     * stays prose.
     */
    internal fun footer(line: String): Footer? {
        var searchEnd = line.length
        while (searchEnd >= sourcesLabel.length) {
            val found = line.lastIndexOf(sourcesLabel, startIndex = searchEnd - sourcesLabel.length, ignoreCase = true)
            if (found < 0) break
            val before = line.substring(0, found)
            val tail = line.substring(found + sourcesLabel.length)
            if (isCitationTail(tail) && (isBlank(before) || endsSentence(before))) return Footer(before, ordinals(tail))
            searchEnd = found
        }
        return null
    }

    /**
     * Splits the prose from the citation line, wherever the model put it.
     *
     * One rule: **a footer is a run of citations at one end of the answer, and
     * it never swallows prose.** The form this replaces took everything from a
     * line-opening label to the end of the string as the citation line without
     * checking what that was — so a model that wrote its footer first and its
     * answer after had the whole answer eaten, and the reader was shown a card
     * with three sources and nothing above them. It shipped in 1.2.0 (41).
     */
    internal fun splitSources(raw: String): Pair<String, List<Int>> {
        val lines = raw.split("\n")
        val content = lines.indices.filter { !isBlank(lines[it]) }
        val first = content.firstOrNull() ?: return raw to emptyList()
        val last = content.last()

        // The shape the instructions ask for: a footer on the final line.
        val closing = footer(lines[last])
        if (closing != null) {
            val body = (lines.subList(0, last) + closing.beforeLabel).joinToString("\n")
            if (!isBlank(body)) return body to closing.citations
            // A footer with no prose before it and none after it is not an
            // answer at all. Said plainly, so the engine can tell the reader so
            // rather than drawing an empty card at them.
            if (first == last) return "" to closing.citations
        }

        // The shape that blanked the answer: a footer first, the answer after.
        if (first != last) {
            val opening = footer(lines[first])
            if (opening != null && isBlank(opening.beforeLabel)) {
                return lines.subList(first + 1, lines.size).joinToString("\n") to opening.citations
            }
        }
        return raw to emptyList()
    }

    /**
     * The ordinals in a citation line, and only the ordinals.
     *
     * The excerpts the model is shown are literally `[1] (Section 3) …`, and a
     * small model copies that shape into its footer — so "Sources: 1 and 2
     * (Section 4)" must not yield the 4. A number introduced by the word
     * "section" is the chapter an excerpt came from, never a citation. Only
     * the word *immediately* before a number introduces it.
     */
    internal fun ordinals(tail: String): List<Int> {
        val ordinals = ArrayList<Int>()
        var lastWord = ""
        val current = StringBuilder()
        var isDigits = false

        fun finish() {
            if (current.isEmpty()) return
            val token = current.toString()
            current.setLength(0)
            if (!isDigits) {
                lastWord = token
                return
            }
            val introducedByChapter = lastWord in chapterWords
            lastWord = ""
            if (introducedByChapter) return
            // Swift's `Int(_:)` reads ASCII digits only, and overflows to nil.
            if (!token.all { it in '0'..'9' }) return
            token.toIntOrNull()?.let(ordinals::add)
        }

        var index = 0
        while (index < tail.length) {
            val codePoint = tail.codePointAt(index)
            index += Character.charCount(codePoint)
            if (isSwiftNumber(codePoint)) {
                if (!isDigits) finish()
                isDigits = true
                current.appendCodePoint(codePoint)
            } else if (isSwiftLetter(codePoint)) {
                if (isDigits) finish()
                isDigits = false
                current.append(String(Character.toChars(codePoint)).lowercasedSwift())
            } else {
                finish()
            }
        }
        finish()
        return ordinals
    }

    /**
     * Whether this text is the "not yet" sentinel, and nothing else.
     *
     * Compared on letters only. The model reliably produces the sentence and
     * unreliably produces its punctuation — a straight apostrophe for a curly
     * one, a full stop dropped, "has not" for "hasn't".
     *
     * **Equal, not contained.** As a substring test, an answer that merely
     * *included* the sentence was a refusal that kept its prose and its
     * citations, and the vetting pass skips a refusal: the spoiler was shown
     * in full.
     */
    internal fun isNotYet(text: String): Boolean {
        val needle = letters(notYetSentinel)
        val haystack = letters(text)
        if (haystack.isEmpty()) return false
        if (haystack == needle) return true
        // "has not" where the sentinel says "hasn't". Compared with the spaces
        // taken out as well, because the contraction the model expanded also
        // added a word boundary that was not there before.
        val expanded = needle.replace(" ", "").replace("hasnt", "hasnot")
        return haystack.replace(" ", "") == expanded
    }

    internal fun letters(text: String): String {
        val kept = StringBuilder()
        val lowered = text.lowercasedSwift()
        var index = 0
        while (index < lowered.length) {
            val codePoint = lowered.codePointAt(index)
            index += Character.charCount(codePoint)
            if (isSwiftLetter(codePoint) || codePoint == ' '.code) kept.appendCodePoint(codePoint)
        }
        return kept.split(' ').filter { it.isNotEmpty() }.joinToString(" ")
    }
}
