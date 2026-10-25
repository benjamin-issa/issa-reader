package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.render.TextRange
import java.util.regex.Pattern

/**
 * One sentence that says something, and the window the model is shown it in.
 *
 * The unit of retrieval used to be a paragraph, and that is what went wrong.
 * Asked "Who is Ryn?" at the Epilogue of a real book, BM25 returned the six
 * paragraphs that said her name most often — which are action scenes, not
 * introductions — and the model stitched a biography out of the nouns standing
 * near her. Asked for her brother's name, the one sentence in the book that
 * says "Her brother, Dask, had trained her…" sat at rank 50 of a pool capped
 * at 40, and the answer was "Sorrel".
 *
 * A sentence that predicates something of the subject is a different object
 * from a paragraph that mentions it, and the difference is the whole feature.
 */
data class Evidence(
    /**
     * What the model is shown: the sentence, and where the antecedent matters
     * the sentence before it. Real chapter offsets, so it is still a location
     * in the book and still inside the boundary.
     */
    val excerpt: Passage,
    /** The sentence the evidence rests on, in chapter coordinates. */
    val sentence: TextRange,
    val role: Role,
    /** The sentence's own text. */
    val sentenceText: String,
    /**
     * The sentence before it in the same passage — the whole of the reach the
     * kinship extractor is allowed, and deliberately one sentence: over-reach
     * is a confident wrong answer with a citation on it.
     */
    val precedingText: String? = null,
    /**
     * How badly the question wants this piece, zero best — carried through to
     * [PassageRanker.Ranked] so the trimming and the retry ladder drop the
     * weakest evidence rather than the last thing the reader read.
     *
     * Defaulted, unlike `Ranked.priority`, because a piece of evidence is
     * minted in a dozen places that have no opinion about rank yet;
     * `prioritised` stamps a whole run of them once the order is decided.
     */
    val priority: Int = 0,
) {
    /**
     * Why this sentence was kept. Not the order it is kept in — that is
     * [priority], and evidence comes back in reading order whatever its role.
     */
    enum class Role {
        /** The first sentence in an early passage that names the subject. Novels introduce people where they first appear. */
        FIRST_MENTION,

        /** The sentence says X *was* something, or calls X something. */
        PREDICATE,

        /** The sentence uses a family word about X. */
        KINSHIP,

        /** A whole passage, for the general path and for topping up. */
        PASSAGE,
    }
}

/**
 * Picks the sentences that say something about the subject.
 *
 * "FTS narrows, sentences decide." The store has already returned a bounded,
 * book-ordered set of passages that must contain the subject; this splits only
 * those, so the cost is a function of how often the subject is named rather
 * than of how long the book is.
 */
object EvidenceFinder {
    /** Every number the finder has an opinion about. */
    object Limits {
        /**
         * How many of the earliest passages contribute a first mention. A
         * character is introduced once and referred to for ever after, and the
         * introduction is what "who is X" is asking for.
         */
        const val firstMentionPassages = 10

        /** How many sentences that predicate something of X are kept. */
        const val predicateSentences = 16

        /**
         * One excerpt in this many is held back for a first mention when both
         * pools are full. A main character is named in every early passage and
         * described in a dozen sentences, so handing the cap a plain
         * concatenation spends it on introductions before a single predicate
         * is reached.
         */
        const val firstMentionShare = 3

        /**
         * The ceiling on identity excerpts. Fifteen sentence-windows of about
         * sixty words is roughly 1,200 tokens — inside the budget, and still
         * less than six whole paragraphs cost.
         */
        const val identityExcerpts = 15

        /**
         * How many kin sentences are kept. Below the excerpt count on purpose:
         * past a dozen, another sentence carrying the same family word about
         * the same person is not more evidence, it is the same evidence again.
         */
        const val kinshipSentences = 12
    }

    // Identity

    /**
     * The sentences that introduce X and the sentences that say what X is.
     *
     * @param passages bounded, in book order, every one containing the
     *   subject. Book order is what makes the store's `LIMIT` keep the
     *   introductions instead of the action scenes.
     * @param limit how many excerpts the question is allowed.
     */
    fun identity(subject: Subject, passages: List<RetrievedPassage>, limit: Int = Limits.identityExcerpts): List<Evidence> {
        val patterns = Patterns(subject)
        val firstMentions = ArrayList<Evidence>()
        val predicates = ArrayList<Evidence>()

        for (passage in passages) {
            if (firstMentions.size >= Limits.firstMentionPassages && predicates.size >= Limits.predicateSentences) break
            val sentences = split(passage)
            var namedInThisPassage = false
            for ((index, sentence) in sentences.withIndex()) {
                if (!patterns.mentions(sentence.text)) continue
                if (!namedInThisPassage) {
                    namedInThisPassage = true
                    if (firstMentions.size < Limits.firstMentionPassages) {
                        // Plus the sentence after it: an introduction is
                        // regularly "X came in. She was the smith's daughter."
                        firstMentions.add(
                            evidence(
                                sentences, from = index, key = index, through = minOf(index + 1, sentences.size - 1),
                                retrieved = passage, role = Evidence.Role.FIRST_MENTION,
                            ),
                        )
                    }
                }
                if (predicates.size >= Limits.predicateSentences || !patterns.saysSomethingAbout(sentence.text)) continue
                predicates.add(
                    evidence(sentences, from = index, key = index, through = index, retrieved = passage, role = Evidence.Role.PREDICATE),
                )
            }
        }
        // De-duplicated *before* the cap, because a sentence can be both the
        // first mention of X and a sentence that predicates something of X —
        // "Dask came in. He was her brother." is one of each — and capping
        // first spends slots on excerpts that are about to be discarded.
        val kept = deduplicated(firstMentions + predicates)
        val introductions = kept.filter { it.role == Evidence.Role.FIRST_MENTION }
        val statements = kept.filter { it.role == Evidence.Role.PREDICATE }
        // A share of the budget each, rather than a prefix of the two lists
        // concatenated. One slot in three is held for an introduction, and
        // either pool spills into whatever the other leaves, so a minor
        // character with two predicates still gets ten arrivals.
        val room = maxOf(1, limit)
        val reserved = minOf(introductions.size, maxOf(1, room / Limits.firstMentionShare))
        val fromStatements = minOf(statements.size, room - reserved)
        val fromIntroductions = minOf(introductions.size, room - fromStatements)
        // Then first mentions first when there is not room for everything, and
        // that preference is written down as a priority before book order is
        // restored.
        return inBookOrder(prioritised(introductions.take(fromIntroductions) + statements.take(fromStatements)))
    }

    // Kinship

    /**
     * Sentences using a family word about X.
     *
     * The subject must be named in the sentence itself or in the one
     * immediately before it, and when it is the one before, that sentence
     * comes into the window — "Ryn had been raised on the streets. Her
     * brother, Dask, had trained her" only answers the question with both
     * halves present.
     *
     * A sentence that *states* the relative's name ranks ahead of one that
     * merely uses the family word, and only then does book order decide: a
     * novel states a relationship where the relative is introduced, and refers
     * to him for ever after. This is the judgement [KinshipExtractor] already
     * makes, so when the fast path declines, the sentences it read names out
     * of are the ones a trimmed prompt keeps.
     */
    fun kinship(
        subject: Subject,
        relation: KinRelation?,
        passages: List<RetrievedPassage>,
        limit: Int = Limits.kinshipSentences,
    ): List<Evidence> {
        val patterns = Patterns(subject)
        val kin = Patterns.kinExpression(relation) ?: return emptyList()
        val named = ArrayList<Evidence>()
        val unnamed = ArrayList<Evidence>()

        for (passage in passages) {
            val sentences = split(passage)
            for ((index, sentence) in sentences.withIndex()) {
                if (!patterns.matches(kin, sentence.text)) continue
                val namesHere = patterns.mentions(sentence.text)
                val namesBefore = index > 0 && patterns.mentions(sentences[index - 1].text)
                if (!namesHere && !namesBefore) continue
                val piece = evidence(
                    sentences, from = if (namesHere) index else index - 1, key = index, through = index,
                    retrieved = passage, role = Evidence.Role.KINSHIP,
                )
                // The extractor's own table, asked whether this one sentence
                // names anybody — a rank, not an answer, which is why it is
                // asked with no known names: it is the fast path, not this,
                // that must decline a sentence-opening capital.
                val names = KinshipExtractor.names(
                    subject = subject, relation = relation, patterns = patterns,
                    sentence = piece.sentenceText, preceding = piece.precedingText, knownNames = emptySet(),
                )
                if (names.isEmpty()) unnamed.add(piece) else named.add(piece)
                if (named.size + unnamed.size == limit) return inBookOrder(prioritised(named + unnamed))
            }
        }
        return inBookOrder(prioritised(named + unnamed))
    }

    // Priority

    /**
     * Stamps a run of evidence with the order it is already in, before
     * anything sorts that order away.
     */
    internal fun prioritised(evidence: List<Evidence>): List<Evidence> =
        evidence.mapIndexed { index, piece -> piece.copy(priority = index) }

    // Whole passages

    /**
     * Passages as they come, for the general path and for topping up a kinship
     * question that found too little. The ranker's priority comes with them,
     * one for one and in the order it was given.
     */
    fun passages(ranked: List<PassageRanker.Ranked>): List<Evidence> = ranked.map {
        Evidence(
            excerpt = it.passage,
            sentence = it.passage.range,
            role = Evidence.Role.PASSAGE,
            sentenceText = it.passage.displayText,
            priority = it.priority,
        )
    }

    /**
     * Back into the shape the prompt builder and the sheet already speak.
     *
     * One for one and in the same order, which the citations depend on:
     * [KinshipExtractor] cites `evidenceIndex + 1` into the list this was
     * built from, so an excerpt dropped or moved here is an answer pointing at
     * a sentence it was not lifted from.
     */
    fun ranked(evidence: List<Evidence>): List<PassageRanker.Ranked> = evidence.map {
        PassageRanker.Ranked(RetrievedPassage(it.excerpt, bm25 = 0.0, isTruncated = false), priority = it.priority)
    }

    // Sentences

    /** One sentence of one passage, in both coordinate systems it needs. */
    internal data class Sentence(
        /** Within the passage's own text. */
        val local: TextRange,
        /** In the chapter, which is where the boundary lives. */
        val chapter: TextRange,
        val text: String,
    )

    internal fun split(retrieved: RetrievedPassage): List<Sentence> {
        val text = retrieved.passage.text
        return SentenceSplitter.ranges(text, TextRange(0, text.length)).map { local ->
            Sentence(
                local = local,
                chapter = TextRange(retrieved.passage.start + local.location, local.length),
                text = text.substring(local.location, local.end),
            )
        }
    }

    /**
     * Lowercased and diacritics folded, for matching only — never for offsets,
     * because folding can change a string's length.
     *
     * Called for the sentences that pass the cheap guard in
     * [Patterns.mentions] and nowhere else: folding every sentence up front
     * measured at 33 ms on a 300,000-word book.
     */
    internal fun fold(text: String): String = text.folded()

    /**
     * Builds one piece of evidence out of a run of sentences.
     *
     * The window's `start` and `end` are real chapter offsets, so the excerpt
     * is a location in the book rather than a quotation floating free of it —
     * and its text is the chapter's own characters at exactly that range.
     */
    internal fun evidence(
        sentences: List<Sentence>,
        from: Int,
        key: Int,
        through: Int,
        retrieved: RetrievedPassage,
        role: Evidence.Role,
    ): Evidence {
        val text = retrieved.passage.text
        val first = sentences[maxOf(0, minOf(from, sentences.size - 1))]
        val last = sentences[maxOf(0, minOf(through, sentences.size - 1))]
        val local = TextRange(first.local.location, maxOf(first.local.length, last.local.end - first.local.location))
        val window = text.substring(local.location, local.end)
        val excerpt = Passage(
            spineIndex = retrieved.passage.spineIndex,
            ordinal = retrieved.passage.ordinal,
            start = retrieved.passage.start + local.location,
            end = retrieved.passage.start + local.end,
            words = PassageChunker.wordCount(window),
            text = window,
        )
        return Evidence(
            excerpt = excerpt,
            sentence = sentences[key].chapter,
            role = role,
            sentenceText = sentences[key].text,
            precedingText = if (key > 0) sentences[key - 1].text else null,
        )
    }

    /**
     * One piece per key sentence, keeping the first — which is the best one,
     * because every finder assembles its evidence best-first.
     *
     * Keyed on the spine index as well as the range, because `sentence` is an
     * offset *within its chapter*: two chapters that open with sentences of
     * the same length would otherwise be called the same sentence, and the
     * one thrown away could be the only evidence there was.
     */
    internal fun deduplicated(evidence: List<Evidence>): List<Evidence> {
        val seen = HashSet<Triple<Int, Int, Int>>()
        return evidence.filter { seen.add(Triple(it.excerpt.spineIndex, it.sentence.location, it.sentence.length)) }
    }

    /**
     * Reading order, with anything already inside an earlier window dropped.
     *
     * Two overlapping windows are the same text twice, numbered as two
     * excerpts — which spends the budget twice and invites the model to cite
     * one fact as two sources.
     */
    internal fun inBookOrder(evidence: List<Evidence>): List<Evidence> {
        val ordered = deduplicated(evidence).sortedWith(compareBy({ it.excerpt.spineIndex }, { it.excerpt.start }))
        val kept = ArrayList<Evidence>()
        for (piece in ordered) {
            val last = kept.lastOrNull()
            if (last != null && last.excerpt.spineIndex == piece.excerpt.spineIndex &&
                piece.sentence.location < last.excerpt.end
            ) {
                continue
            }
            kept.add(piece)
        }
        return kept
    }
}

/**
 * The regular expressions one question needs, compiled once.
 *
 * Once per question, never per sentence: a 300-passage scan is a couple of
 * thousand sentences, and compiling in that loop would cost more than the scan
 * it is part of. The cheap `contains` guard in [mentions] comes first for the
 * same reason — most sentences of a passage do not name the subject at all,
 * and a substring search settles that in nanoseconds.
 *
 * Written against ICU's regular expressions, which is what
 * `NSRegularExpression` is: `\b` and `\s` there are Unicode-aware, and Java's
 * are not by default, so the two are spelled out ([BOUNDARY], [SPACE]) rather
 * than left to a flag one platform's regex engine reads differently.
 */
internal class Patterns(subject: Subject) {
    val head: String
    val mention: Pattern?
    val predicates: List<Pattern>

    init {
        val tokens = subject.tokens.filter { it.isNotEmpty() }
        head = tokens.lastOrNull() ?: ""
        // A multi-word name is used in full once and by its head thereafter:
        // "a White Rabbit with pink eyes" becomes "the Rabbit" three lines
        // later, and only the second form is in most of the sentences.
        val spelled = tokens.joinToString("$SPACE+") { Pattern.quote(it) }
        val alternatives = if (tokens.size > 1) "(?:$spelled|${Pattern.quote(head)})" else spelled
        mention = if (tokens.isEmpty()) null else expression("$BOUNDARY$alternatives$BOUNDARY")

        predicates = if (tokens.isEmpty()) {
            emptyList()
        } else {
            val copulas = "was|is|were|are|had been|became"
            listOf(
                // "Ryn was a Ferrant." / "The Duchess is the one who…"
                "$BOUNDARY$alternatives$BOUNDARY$SPACE+(?:$copulas)$BOUNDARY",
                // "Ryn, the Heir of the Marches, …"
                "$BOUNDARY$alternatives$BOUNDARY$SPACE*,$SPACE*(?:the|a|an)$BOUNDARY",
                // "Ryn, who had been raised on the streets, …"
                "$BOUNDARY$alternatives$BOUNDARY$SPACE*,?$SPACE+who$BOUNDARY",
                // "…a girl called Ryn." / "…was named Ryn." The optional
                // pronoun is there because "the crew called her Ryn" is how a
                // book most often says what somebody is called.
                "$BOUNDARY(?:was|is|called|named)$SPACE+(?:him|her|them|it|the|a|an)?$SPACE*$alternatives$BOUNDARY",
            ).mapNotNull(::expression)
        }
    }

    /** Whether this sentence names the subject. */
    fun mentions(sentence: String): Boolean {
        val mention = mention ?: return false
        if (!couldMention(sentence)) return false
        return matches(mention, EvidenceFinder.fold(sentence))
    }

    fun saysSomethingAbout(sentence: String): Boolean {
        if (!couldMention(sentence)) return false
        val folded = EvidenceFinder.fold(sentence)
        return predicates.any { matches(it, folded) }
    }

    /**
     * The cheap half. Most sentences of a passage do not name the subject at
     * all, and one case- and diacritic-insensitive search settles that.
     */
    fun couldMention(sentence: String): Boolean {
        if (head.isEmpty()) return false
        return EvidenceFinder.fold(sentence).contains(head)
    }

    fun matches(expression: Pattern, text: String): Boolean = expression.matcher(text).find()

    companion object {
        /** ICU's `\w`, near enough: letters, marks, digits and connectors. */
        private const val WORD = "[\\p{L}\\p{M}\\p{Nd}\\p{Pc}\\u200C\\u200D]"

        /** ICU's `\b`: a change from a word character to anything else, or back. */
        const val BOUNDARY = "(?:(?<=$WORD)(?!$WORD)|(?<!$WORD)(?=$WORD))"

        /** ICU's `\s`: tab, the line breaks, and every Unicode separator. */
        const val SPACE = "[\\t\\n\\u000B\\f\\r\\u0085\\p{Z}]"

        fun expression(pattern: String, flags: Int = 0): Pattern? = try {
            Pattern.compile(pattern, flags)
        } catch (_: Exception) {
            null
        }

        /**
         * One expression over every spelling of every relation, or over the
         * asked-about group when the question named one.
         *
         * The group rather than the word, because a novel introduces a brother
         * once and then uses his name: the sentence a reader is asking about
         * may say "sibling" or "sister" and never "brother".
         */
        fun kinExpression(relation: KinRelation?): Pattern? {
            val words = relation?.let { (it.forms + it.group).toSet() } ?: KinRelation.allForms.toSet()
            if (words.isEmpty()) return null
            val alternation = words
                .sortedWith { left, right -> if (left.length == right.length) left.compareTo(right) else right.length.compareTo(left.length) }
                .joinToString("|") { Pattern.quote(it) }
            // Case-insensitive rather than folded, so this can run on the book's
            // own text: family words carry no diacritics, and folding every
            // sentence to find them costs more than the search does.
            return expression("$BOUNDARY(?:$alternation)$BOUNDARY", Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE)
        }
    }
}
