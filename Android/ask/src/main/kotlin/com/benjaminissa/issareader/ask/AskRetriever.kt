package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.core.diagnostics.IssaLog

/**
 * Everything between a reader's question and the excerpts the model is shown.
 *
 * The shape is "FTS narrows, sentences decide". The store returns a bounded,
 * book-ordered set of passages that must contain the subject; [EvidenceFinder]
 * splits only those and keeps the sentences that say something; the kinship
 * table answers outright when the book states one name and only one.
 *
 * The splitting runs here rather than inside [AskIndexStore] on purpose. The
 * store also deletes index files when a download goes, and a
 * two-thousand-sentence scan holding its lock would queue that deletion behind
 * CPU work for no reason.
 *
 * @param bookUuid which book, captured beside the boundary and for the same
 *   reason: one store serves every book on the shelf, so a retriever that left
 *   the book to be settled per query could have its second query answered
 *   from a different one than its first.
 * @param allowsFastPath whether the deterministic kinship table may answer
 *   without the model: [AskEngine.usesKinshipFastPath] for the engine.
 * @param recencyPassages how many of the passages just read to add behind what
 *   the search found.
 */
class AskRetriever(
    private val store: AskIndexStore,
    private val bookUuid: String,
    private val boundary: ReadingBoundary,
    private val allowsFastPath: Boolean = true,
    private val recencyPassages: Int = Limits.recencyPassages,
) {
    /** What retrieval decided. */
    sealed interface Retrieval {
        /**
         * The question names something the book has not used yet, or nothing
         * matched at all. Either way the honest answer is that the story has
         * not revealed it, and the model is never asked.
         */
        data class NotYet(val unmet: List<String>) : Retrieval

        /** Excerpts for the model, and what kind of question produced them. */
        data class Found(val ranked: List<PassageRanker.Ranked>, val kind: QuestionKind) : Retrieval

        /**
         * The book states the answer in so many words. The evidence comes with
         * it so the caller can still show what it rests on.
         */
        data class Answered(val answer: AskAnswer, val evidence: List<PassageRanker.Ranked>) : Retrieval
    }

    /** Every number retrieval has an opinion about, in one place so a test can assert against the shipped ones. */
    object Limits {
        /**
         * How many of the book's names a question is read against. Generous:
         * it costs one indexed query, and a name the list misses is a question
         * that silently retrieves the wrong paragraphs.
         */
        const val knownNames = 200

        /**
         * Excerpts for a question, whatever kind of question it is.
         *
         * Fifteen, not six. A 280-answer trial against a novel the model has
         * *not* memorised scored six excerpts at 3.40/10 and twenty at 5.10;
         * the earlier "fewer is better" finding came from books it knew by
         * heart, where thin retrieval was quietly covered by recall.
         *
         * One number for all four kinds of question, because until this was
         * written down it reached exactly one of them.
         */
        const val excerpts = 15

        /**
         * The most excerpts any window is given, however large. Twenty is the
         * most any trial has scored; thirty leaves room to measure past it
         * without letting a future window send a quarter of the book.
         */
        const val excerptsCeiling = 30

        /**
         * Excerpts for a window this size: [excerpts] at the 4,096 tokens the
         * number was measured against, growing in proportion above it, and
         * never fewer — a smaller window is trimmed by the prompt builder,
         * which is the layer that can count.
         */
        fun excerpts(contextSize: Int): Int {
            val tuned = AskPromptBuilder.Budget.tunedContextSize
            val scaled = excerpts * maxOf(contextSize, tuned) / tuned
            return minOf(excerptsCeiling, scaled)
        }

        /** The BM25 pool a general question ranks. Raised from 40, which is where the sentence naming Ryn's brother was sitting at rank 50. */
        const val generalPool = 120

        /** The evidence scan's ceiling. In book order, so the three hundred it keeps are the earliest — where introductions live. */
        const val evidencePool = 300

        /**
         * The passages just before the reader's position that every non-recap
         * question is also shown, behind what the search found. Twelve
         * passages is about 1,100 words — the page or two the reader has just
         * turned. Measured in the 1.4.0 Ask review: it took hand-graded
         * answers from 19.5 to 23.5 of 26, with no spoiler and no passage past
         * the boundary.
         */
        const val recencyPassages = 12

        /**
         * Below this a kinship question is topped up with ordinary passages,
         * so a book that states a relationship once is not answered from one
         * sentence with no context around it. It is topped up to the limit.
         */
        const val kinshipFloor = 3
    }

    // Asking

    suspend fun retrieve(question: String, limit: Int = Limits.excerpts): Retrieval {
        // The book's own names, bounded by the position, so an invented one the
        // general-purpose finder misses ("Cheshire", "Ryn") is still recognised
        // as a name — and a character not yet met is still not.
        val known = runCatching { store.topNames(bookUuid, boundary, Limits.knownNames) }.getOrElse {
            if (it is kotlinx.coroutines.CancellationException) throw it
            emptyList()
        }
        // Thrown rather than defaulted: these decide which of the reader's
        // lower-case words the probe below checks, and an empty set would
        // quietly check fewer.
        val bookNames = store.nameWords(bookUuid)
        val terms = QueryTerms.extract(question, knownNames = known, bookNames = bookNames)

        // Every question, a recap's included. "What has happened so far?" names
        // nobody and probes nothing — but "What has happened to the Cheshire
        // Cat?" is a recap by its pattern, and skipping the probe for it took
        // the recap passages and let the model describe the Cat from memory
        // (R-04).
        val unmet = store.unmetWords(terms.nameCandidates, bookUuid, boundary)
        // Retrieval is skipped when the answer is already known to be "not
        // yet": it would only cost a query whose results are thrown away.
        if (unmet.isNotEmpty()) return Retrieval.NotYet(unmet)

        if (terms.isRecap) {
            val recap = store.recapPassages(bookUuid, boundary, limit)
            // A reader who opens the sheet before reading a word. The recap is
            // the first chip on it, so this is one tap away — and without the
            // guard it ran a generation over no excerpts at all.
            if (recap.isEmpty()) return Retrieval.NotYet(emptyList())
            return Retrieval.Found(recapRanked(recap), QuestionKind.Recap)
        }

        var found = evidence(terms, limit)
        if (found.isEmpty() && terms.kind.subject != null) {
            // A subject the book uses but never says anything about. Better a
            // paragraph that mentions them than the sentinel.
            found = general(terms, subject = null, limit = limit)
        }
        if (found.isEmpty()) return Retrieval.NotYet(emptyList())

        val kind = terms.kind
        if (allowsFastPath && kind is QuestionKind.Kinship) {
            val answer = KinshipExtractor.answer(
                subject = kind.subject, relation = kind.relation, form = kind.form, evidence = found,
                knownNames = known.map { NameFinder.Name.key(it) }.toSet(),
            )
            if (answer != null) {
                IssaLog.info("ask answered from the book's own sentence")
                return Retrieval.Answered(answer, EvidenceFinder.ranked(found))
            }
        }
        val ranked = EvidenceFinder.ranked(found)
        if (recencyPassages <= 0) return Retrieval.Found(ranked, terms.kind)
        val recent = store.recapPassages(bookUuid, boundary, recencyPassages)
        return Retrieval.Found(withRecency(ranked, inReadersChapter(recent, boundary)), terms.kind)
    }

    /**
     * The sentences, before they are packaged. Public so a test can assert on
     * the evidence itself rather than on what the prompt did with it.
     *
     * @param limit the ceiling on excerpts, and it reaches every branch.
     */
    suspend fun evidence(terms: QueryTerms, limit: Int = Limits.excerpts): List<Evidence> =
        when (val kind = terms.kind) {
            QuestionKind.Recap -> EvidenceFinder.passages(recapRanked(store.recapPassages(bookUuid, boundary, limit)))
            is QuestionKind.Identity -> identity(kind.subject, limit)
            is QuestionKind.Kinship -> kinship(terms, kind.subject, kind.relation, kind.other, limit)
            is QuestionKind.General -> general(terms, kind.subject, limit)
        }

    // Identity

    /**
     * "Who is X?" — the sentences that introduce X and the sentences that say
     * what X is.
     *
     * Two queries for a multi-word name, because a book uses the full name
     * once and the short form thereafter: *Alice* meets "a White Rabbit with
     * pink eyes" in one paragraph and "the Rabbit" with its watch and its
     * waistcoat in the next, and requiring both words of every passage throws
     * away the second — which is the only one that says anything about him.
     *
     * The short form is admitted only from the full name's first appearance
     * onwards. Before it, the head is a different thing entirely: "cat" ten
     * chapters before the Cheshire Cat is Dinah.
     */
    private suspend fun identity(subject: Subject, limit: Int): List<Evidence> {
        val strict = FtsQuery.all(subject.tokens) ?: return emptyList()
        var passages = store.passages(strict, bookUuid, boundary, PassageOrder.BOOK_ORDER, Limits.evidencePool)
        val introduction = passages.firstOrNull()
        val short = FtsQuery.all(listOf(subject.head))
        if (subject.tokens.size > 1 && introduction != null && short != null) {
            val anchor = introduction.passage.spineIndex to introduction.passage.start
            val shortForm = store.passages(short, bookUuid, boundary, PassageOrder.BOOK_ORDER, Limits.evidencePool)
                .filter { compare(it.passage.spineIndex to it.passage.start, anchor) >= 0 }
            passages = merged(passages, shortForm)
        }
        logIfCapped(passages.size, "identity")
        // Both ceilings: what this question is allowed, and what the finder
        // thinks is worth reading about one person however much room there is.
        return EvidenceFinder.identity(subject, passages, minOf(limit, EvidenceFinder.Limits.identityExcerpts))
    }

    // Kinship

    /**
     * "Who is X's brother?" — sentences with a family word that are about X.
     *
     * The query requires X and asks for the relation's whole group, because a
     * novel introduces a brother once and then uses his name: the sentence
     * that answers the question may say "sibling" and never "brother".
     */
    private suspend fun kinship(
        terms: QueryTerms,
        subject: Subject,
        relation: KinRelation?,
        other: Subject?,
        limit: Int,
    ): List<Evidence> {
        val pattern = if (other != null) {
            // "How are X and Y related?" and "Is Y X's brother?" are both
            // answered by the paragraph where the two of them appear together.
            FtsQuery.all(subject.tokens + other.tokens)
        } else {
            val words = relation?.let { (it.forms.toSet() + it.group).toList() } ?: KinRelation.allForms
            FtsQuery.all(subject.tokens, andAnyOf = words)
        } ?: return emptyList()

        val passages = store.passages(pattern, bookUuid, boundary, PassageOrder.BOOK_ORDER, Limits.evidencePool)
        logIfCapped(passages.size, "kinship")
        // Both ceilings, as on the identity path.
        val found = EvidenceFinder.kinship(subject, relation, passages, minOf(limit, EvidenceFinder.Limits.kinshipSentences))
        if (found.size >= Limits.kinshipFloor) return found

        // Too little to read. Top up with ordinary passages that still have to
        // contain the subject, so the model has some context rather than one
        // sentence standing on its own — up to the limit, which a constant of
        // six here once overrode.
        val extra = general(terms, subject, limit - found.size)
        return toppedUp(found, extra)
    }

    // General

    /**
     * Everything else: BM25, with the subject required when there is one.
     *
     * The fallback to a plain OR matters. A subject the classifier picked up
     * from a capital that was not a name would otherwise retrieve nothing at
     * all, and the reader would be told the story had not revealed something
     * it had.
     */
    private suspend fun general(terms: QueryTerms, subject: Subject?, limit: Int): List<Evidence> {
        var candidates: List<RetrievedPassage> = emptyList()
        if (subject != null) {
            val others = optionalTerms(terms, subject)
            val pattern = FtsQuery.all(subject.tokens, andAnyOf = others)
            if (pattern != null) {
                candidates = store.passages(pattern, bookUuid, boundary, PassageOrder.RELEVANCE, Limits.generalPool)
            }
        }
        if (candidates.isEmpty()) candidates = store.retrieve(terms, bookUuid, boundary, Limits.generalPool)
        if (candidates.isEmpty()) return emptyList()
        return EvidenceFinder.passages(PassageRanker.rank(candidates, terms, maxOf(1, limit)))
    }

    // Logging

    /**
     * Never the question and never the words: a log is exported by the reader
     * and pasted into an email. The count is what says whether the cap is
     * biting on a long book, which is the only thing that would need tuning.
     */
    private fun logIfCapped(count: Int, kind: String) {
        if (count < Limits.evidencePool) return
        IssaLog.debug("ask evidence scan hit the cap", mapOf("kind" to kind, "passages" to count.toString()))
    }

    companion object {
        /**
         * The recent passages that are in the spine item the reader is in.
         *
         * The recap query walks back across spine items, which for a recap is
         * the point. For the top-up it is not: on the first pages of a book
         * the twelve passages before the reader reach past Chapter 1 into
         * whatever came before it, and a title page or copyright page the book
         * never tagged is indexed like any chapter — so every question asked
         * there sent the title and the author's name, which the prompt never
         * sends (R-26). The spine item the reader is standing in is story by
         * definition.
         */
        internal fun inReadersChapter(recent: List<RetrievedPassage>, boundary: ReadingBoundary): List<RetrievedPassage> =
            recent.filter { it.passage.spineIndex == boundary.spineIndex }

        /**
         * What the search found, with the pages just read behind it.
         *
         * The search finds the sentences that name the question's words; the
         * answer is very often in the paragraphs around where the reader is,
         * which name none of them. They rank behind everything the search
         * found, so a small window drops them first, and a recent passage that
         * overlaps a found excerpt is left out rather than sent twice. Book
         * order, which is what the builder numbers and the model reads.
         */
        internal fun withRecency(found: List<PassageRanker.Ranked>, recent: List<RetrievedPassage>): List<PassageRanker.Ranked> {
            val offset = (found.maxOfOrNull { it.priority } ?: -1) + 1
            val extra = recapRanked(recent).filter { candidate ->
                found.none {
                    it.passage.spineIndex == candidate.passage.spineIndex &&
                        it.passage.start < candidate.passage.end &&
                        candidate.passage.start < it.passage.end
                }
            }.map { PassageRanker.Ranked(it.retrieved, it.priority + offset) }
            return (found + extra).sortedWith(compareBy({ it.passage.spineIndex }, { it.passage.start }))
        }

        /**
         * A recap, read in order but priced by recency.
         *
         * The store hands these back in reading order, which is what the model
         * must see. But "what has happened so far" is a question about the end
         * of what has happened, so when the prompt will not fit it is the
         * opening that should go, not the chapter the reader has just closed.
         */
        internal fun recapRanked(recap: List<RetrievedPassage>): List<PassageRanker.Ranked> =
            recap.mapIndexed { index, passage -> PassageRanker.Ranked(passage, recap.size - 1 - index) }

        /** Two bounded results as one, in book order and still capped. */
        internal fun merged(first: List<RetrievedPassage>, second: List<RetrievedPassage>): List<RetrievedPassage> {
            val seen = HashSet<Pair<Int, Int>>()
            return (first + second)
                .filter { seen.add(it.passage.spineIndex to it.passage.ordinal) }
                .sortedWith(compareBy({ it.passage.spineIndex }, { it.passage.start }))
                .take(Limits.evidencePool)
        }

        /**
         * Kin sentences, with ordinary passages behind them for context.
         *
         * A top-up passage is a whole paragraph, and the paragraph a kin
         * sentence was lifted *from* is one of the passages the same query
         * returns. It is the same text twice, and it is the wider of the two
         * windows, so it sorts ahead of the sentence and `inBookOrder` keeps the
         * paragraph and drops the sentence — which is how a fast path with the
         * answer in front of it stopped firing. So any top-up whose range
         * covers a kin sentence goes.
         *
         * And the offset is one past the *highest* priority found, not the
         * count of them: `inBookOrder` drops overlapping windows, so the
         * priorities it hands back can have gaps in them, and counting gives a
         * context paragraph the same priority as a kin sentence.
         */
        internal fun toppedUp(found: List<Evidence>, extra: List<Evidence>): List<Evidence> {
            val context = extra.filter { passage ->
                found.none {
                    it.excerpt.spineIndex == passage.excerpt.spineIndex &&
                        it.sentence.location in passage.excerpt.range
                }
            }
            val offset = (found.maxOfOrNull { it.priority } ?: -1) + 1
            return EvidenceFinder.inBookOrder(found + context.map { it.copy(priority = it.priority + offset) })
        }

        /**
         * The words a passage about the subject must have at least one of,
         * beside the subject itself.
         *
         * **Not the subject's own family.** A subject that is a family word
         * drags its whole group into the search tokens — "father" brings
         * "mother", "parents", "papa" — and those are other ways of saying the
         * subject, not further things a passage about it has to say.
         *
         * **And not "who" on its own.** "who", "whom" and "whose" stay search
         * tokens because the ranker reads them as the sign that the answer is a
         * person, and beside a content word they only widen the net. But when
         * nothing else is left to require, requiring one of them asks every
         * passage for a relative pronoun, so the subject is required alone.
         *
         * Together they lost a reported case: "Who is the author's father?" on
         * *Franklin* took `father` as its subject, and every passage had to
         * contain "father" and one of "who", "mother", "parents"… — which
         * "Josiah, my father, married young" does not.
         */
        internal fun optionalTerms(terms: QueryTerms, subject: Subject): List<String> {
            val family = Kinship.groups(subject.tokens).flatten().toSet()
            val others = terms.searchTokens.filter { it !in subject.tokens && it !in family }
            return if (others.all { it in QueryTerms.personWords }) emptyList() else others
        }

        private fun compare(left: Pair<Int, Int>, right: Pair<Int, Int>): Int =
            if (left.first != right.first) left.first.compareTo(right.first) else left.second.compareTo(right.second)
    }
}
