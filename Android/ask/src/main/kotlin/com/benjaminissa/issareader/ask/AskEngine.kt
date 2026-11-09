package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.Fnv1a
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.isActive

/**
 * One question, one answer, bounded by where the reader has got to.
 *
 * The engine owns the order of operations, and the order is the feature:
 * prepare the index, search *before the boundary*, rank, pack what fits, and
 * only then call the model. Nothing here reads the book directly; retrieval is
 * a SQL clause in [AskIndexStore] that cannot be persuaded to return a passage
 * from later in the book, and this class's job is to never route around it.
 *
 * Serialising the model is *not* one of its jobs and never could be: the app
 * builds a fresh engine per question, so the turnstile is [AskTurnstile] — one
 * per process, passed in.
 *
 * @param store held publicly because the app also deletes indexes from it when
 *   a download goes, and there must be exactly one per process: two would open
 *   the same SQLite file twice.
 * @param tools nothing, in the app: see [usesSearchTool]. This parameter is how
 *   a test hands the engine one.
 * @param turnstile the process's one turn at the on-device model. Defaulted so
 *   a test that only cares about one question writes nothing; the app passes
 *   the same one to every engine it builds, which is the whole point of the
 *   type.
 * @param usesNucleusSampling defaulted from the kill switch, so the app passes
 *   nothing and gets the shipped behaviour. It exists so the sampled path —
 *   seed, threshold, temperature — is reachable at all; while it was a bare
 *   constant the only test of the seed compared two greedy option values and
 *   could not fail.
 */
class AskEngine(
    private val model: AnswerModel,
    val store: AskIndexStore,
    private val tools: List<AskTool> = emptyList(),
    private val turnstile: AskTurnstile = AskTurnstile(),
    private val usesNucleusSampling: Boolean = AskEngine.usesNucleusSampling,
) {
    // Index

    /**
     * Builds this book's index if it is missing or stale.
     *
     * Separate from [ask] so the sheet can start it the moment it opens, while
     * the reader is still typing: on a long illustrated book the build is the
     * larger half of the first question's latency.
     */
    suspend fun prepareIndex(source: BookSource, progress: (suspend (AskPhase) -> Unit)? = null): Boolean {
        try {
            return store.prepare(source, progress)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            // Never the title, never the question — a log is exported by the
            // reader and pasted into an email.
            IssaLog.error("ask index failed", mapOf("kind" to failure.javaClass.simpleName))
            throw AskFailure.IndexFailed
        }
    }

    /**
     * Warms the model while the reader looks at the chips.
     *
     * Skipped rather than queued when a question already holds the turn: what
     * a prewarm would load, that question has loaded already.
     */
    suspend fun prewarm() {
        turnstile.ifFree { model.prewarm() }
    }

    /**
     * The chips under the question field.
     *
     * Falls back to the generic pair when the index is not built yet, so the
     * sheet has something to draw immediately rather than empty capsules that
     * fill in eight seconds later.
     */
    suspend fun suggestions(source: BookSource, boundary: ReadingBoundary): List<String> {
        if (!store.isPrepared(source)) return AskSuggestions.chips(emptyList())
        val names = try {
            store.topNames(source.bookUuid, boundary, AskSuggestions.namesWanted)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return AskSuggestions.chips(emptyList())
        }
        return AskSuggestions.chips(names)
    }

    // Asking

    /**
     * Everything that happens between the question and the answer.
     *
     * A stream rather than a single value because the phases and the partial
     * text are the difference between "seven seconds of spinner" and a sheet
     * that is visibly working; and because the reader may close the sheet and
     * get a notification, which needs the job to outlive the view either way.
     *
     * Cancelling the collector cancels the whole pipeline — the index build
     * between chapters, the retrieval, and the generation between snapshots —
     * and the flow then ends without [AskEvent.Answered], which the sheet reads
     * as "cancelled". Any other way it ends early is an [AskFailure].
     */
    fun ask(question: String, source: BookSource, boundary: ReadingBoundary): Flow<AskEvent> = channelFlow {
        try {
            answer(question, source, boundary) { send(it) }
        } catch (cancelled: CancellationException) {
            // A cancellation from below — a model that stopped — rather than of
            // this flow: not a failure the reader is told about. The flow ends
            // without an answer, which is what the sheet reads as "cancelled".
            if (currentCoroutineContext().isActive) return@channelFlow
            throw cancelled
        } catch (failure: Throwable) {
            throw failure(failure)
        }
    }

    private suspend fun answer(
        question: String,
        source: BookSource,
        boundary: ReadingBoundary,
        emit: suspend (AskEvent) -> Unit,
    ) {
        currentCoroutineContext().ensureActive()
        // Before anything expensive: a book the model has no language for will
        // fail at the last step otherwise, after a full index build.
        if (!model.supportsLanguage(source.language)) throw AskFailure.UnsupportedLanguage

        prepareIndex(source) { phase -> emit(AskEvent.Phase(phase)) }

        currentCoroutineContext().ensureActive()
        emit(AskEvent.Phase(AskPhase.Retrieving))
        val retriever = AskRetriever(store, source.bookUuid, boundary, allowsFastPath = usesKinshipFastPath)
        // Fifteen on the window the number was measured against, more on a
        // larger one: the builder packs to the ceiling, and the ceiling grows.
        val retrieval = retriever.retrieve(question, AskRetriever.Limits.excerpts(model.contextSize))
        val sanitised = QueryTerms.sanitise(question)

        when (retrieval) {
            // Two ways the answer is "not yet", and both are settled here rather
            // than by the model. Nothing retrieved at all is the obvious one.
            // The other is a question naming somebody the book has not
            // introduced: retrieval happily returns passages about the *other*
            // words in the question, and the model — asked "Who is the
            // Cheshire Cat?" from the end of Chapter I, handed excerpts
            // containing no cat but Dinah — answered from memory, ten chapters
            // ahead of the reader. Instructions that forbade it twice did not
            // stop it; this does.
            is AskRetriever.Retrieval.NotYet -> {
                IssaLog.info("ask answered as not yet revealed", mapOf("unmet" to retrieval.unmet.size.toString()))
                // No sources, and never any: excerpts under "the story hasn't
                // revealed that yet" would be showing the reader proof of an
                // absence.
                emit(AskEvent.Answered(withheld()))
            }

            // The book states the answer in so many words, so there is nothing
            // to think about and no `Thinking` phase to show. It is still
            // vetted: the guard is cheap and an unvetted path is a path
            // somebody will later route around.
            //
            // The evidence is bound rather than dropped, and this is the best
            // citation the feature has: `KinshipExtractor` cites
            // `evidenceIndex + 1` into the very list `EvidenceFinder.ranked`
            // preserved one for one, so the excerpt shown is provably the
            // sentence the answer was lifted from.
            is AskRetriever.Retrieval.Answered -> emit(
                AskEvent.Answered(
                    vetted(
                        AskAnswerParser.resolving(
                            retrieval.answer, numbered(retrieval.evidence.map { it.passage }),
                            priorities(retrieval.evidence),
                        ),
                        source.bookUuid, boundary,
                    ),
                ),
            )

            is AskRetriever.Retrieval.Found -> {
                currentCoroutineContext().ensureActive()
                emit(AskEvent.Phase(AskPhase.Thinking))
                val generated = generate(
                    question = sanitised,
                    ranked = retrieval.ranked,
                    options = generationOptions(sanitised, source.bookUuid, boundary),
                    bookUuid = source.bookUuid,
                    boundary = boundary,
                    emit = emit,
                )
                currentCoroutineContext().ensureActive()
                emit(AskEvent.Answered(vetted(generated, source.bookUuid, boundary)))
            }
        }
    }

    /**
     * What the model is asked to do with its sampler, for this one question.
     *
     * An instance method reading this engine's own flag: as a static it read
     * the constant directly, so nothing could construct an engine that samples
     * and the branch below had no caller in any test.
     */
    internal fun generationOptions(question: String, bookUuid: String, boundary: ReadingBoundary): AskGenerationOptions {
        if (!usesNucleusSampling) return AskGenerationOptions(maximumResponseTokens = AskPromptBuilder.Budget.responseTokens)
        return AskGenerationOptions(
            maximumResponseTokens = AskPromptBuilder.Budget.responseTokens,
            temperature = nucleusTemperature,
            sampling = AskGenerationOptions.Sampling.Nucleus(
                probabilityThreshold = nucleusThreshold,
                seed = seed(question, bookUuid, boundary),
            ),
        )
    }

    // Vetting the answer

    /**
     * The output side of the question-side guard.
     *
     * The question-side guard catches "Who is the Cheshire Cat?" because the
     * name is in the question. It cannot catch the other half of the same
     * defect: a question whose own words are all met — "What does Alice meet
     * in the wood?" — retrieves perfectly bounded passages, and the model
     * answers with a character from ten chapters ahead anyway, because it has
     * read the book. Retrieval was never the leak; the model's memory is. So
     * the answer is held to the same test the question is: every name in it
     * must be a name the book has already used.
     *
     * **Nothing is exempt for being in the question** (R-04): a word the
     * question side did probe and found met is met here too, and a word it did
     * not probe is exactly the hole.
     *
     * The sources are deliberately **not** filtered. Every one of them is book
     * text the reader has already passed: an excerpt exists only because
     * [AskIndexStore] returned it from a query bounded by the boundary.
     */
    private suspend fun vetted(answer: AskAnswer, bookUuid: String, boundary: ReadingBoundary): AskAnswer {
        if (answer.notYetRevealed) return answer
        val candidates = unvettedNames(answer.text)
        if (candidates.isEmpty()) return answer
        val unmet = store.unmetWords(candidates, bookUuid, boundary)
        if (unmet.isEmpty()) return answer
        // Never the words themselves: an unmet name is a spoiler, and the log is
        // exported by the reader and pasted into an email.
        IssaLog.info("ask answered as not yet revealed", mapOf("unmetInAnswer" to unmet.size.toString()))
        // A fresh answer, so the refused one's sources go with its prose.
        return withheld()
    }

    // Generation

    /**
     * Streams an answer, shrinking the prompt if the window says no.
     *
     * The retries are the plan's: all the passages, then half, then two. The
     * builder estimates first and counts with the model second, so the
     * overflow that does happen is the estimate being wrong, and halving is the
     * cheapest way to be certainly right.
     *
     * The turn is taken here rather than around the whole question, and it
     * covers all three attempts. Around the question it queued work that never
     * reaches the model at all: the not-yet answer and the kinship fast path
     * answer from SQL in milliseconds and still waited behind another book's
     * twenty-second generation.
     */
    private suspend fun generate(
        question: String,
        ranked: List<PassageRanker.Ranked>,
        options: AskGenerationOptions,
        bookUuid: String,
        boundary: ReadingBoundary,
        emit: suspend (AskEvent) -> Unit,
    ): AskAnswer = turnstile.withTurn {
        var lastFailure: AskFailure = AskFailure.TooMuchContext
        for (attempt in attempts(ranked)) {
            currentCoroutineContext().ensureActive()
            val built = AskPromptBuilder.build(
                question = question,
                ranked = attempt,
                contextSize = model.contextSize,
                hasTool = tools.isNotEmpty(),
                tokenCount = { text -> model.tokenCount(text) },
            )
            for (tool in tools) tool.beginGeneration(built.passages.size + 1)

            try {
                val answer = stream(built, options, bookUuid, boundary, emit)
                // Resolved here, inside the attempt that survived: the prompt
                // whose numbering the citations refer to is whichever one did
                // not fail for size.
                val shown = numbered(built.passages).toMutableMap()
                // A tool's excerpts continue the prompt's numbering, so they
                // never collide; merged last regardless, because a collision
                // would mean the tool numbered over the prompt and the tool's
                // copy is what the model saw last.
                for (tool in tools) shown.putAll(tool.passagesShown())
                // From this attempt's ranking, not the whole retrieval.
                return@withTurn AskAnswerParser.resolving(answer, shown, priorities(attempt))
            } catch (failure: AskFailure.TooMuchContext) {
                lastFailure = failure
                IssaLog.info("ask prompt too large", mapOf("passages" to built.passages.size.toString()))
            }
        }
        throw lastFailure
    }

    /**
     * Streams one attempt, drawing only what has been vetted.
     *
     * A partial is the answer so far cut back to its last whole word, put
     * through the same test the finished answer gets: every name in it must be
     * one the book has used before the boundary. The first partial that names
     * one it has not stops the drawing for the rest of the attempt — the sheet
     * keeps the last vetted words, and the finished answer is then refused
     * whole by [vetted] (R-16).
     *
     * Streaming survives: a safe answer still arrives a word at a time, one
     * token behind the model, and each name costs one indexed lookup the first
     * time it appears and nothing after. Whole words only, because a name is
     * not a name until it is finished.
     */
    private suspend fun stream(
        built: AskPromptBuilder.Built,
        options: AskGenerationOptions,
        bookUuid: String,
        boundary: ReadingBoundary,
        emit: suspend (AskEvent) -> Unit,
    ): AskAnswer {
        var raw = ""
        var shown = ""
        var hasAnswered = false
        // Names already probed and met, so a name repeated in every snapshot
        // is looked up once; and whether an unmet one has stopped the drawing.
        val met = HashSet<String>()
        var isHeld = false
        model.answer(AskPromptBuilder.instructions, built.prompt, tools, options).collect { snapshot ->
            // Per snapshot: the reader who taps Cancel expects the words to
            // stop arriving, not to finish and then be thrown away.
            currentCoroutineContext().ensureActive()
            // Each snapshot is the answer so far, so it replaces what came
            // before. One that does not carry the text before it is logged, by
            // length and never by text, so the next one is evidence rather
            // than a theory.
            if (!snapshot.startsWith(raw)) {
                IssaLog.info(
                    "ask snapshot was not cumulative",
                    mapOf("previousLength" to raw.length.toString(), "snapshotLength" to snapshot.length.toString()),
                )
            }
            raw = snapshot
            if (isHeld) return@collect
            val visible = AskAnswerParser.visible(wholeWords(raw))
            if (visible == shown) return@collect
            val unprobed = unvettedNames(visible).filter { it !in met }
            if (unprobed.isNotEmpty()) {
                val unmet = store.unmetWords(unprobed, bookUuid, boundary)
                if (unmet.isNotEmpty()) {
                    // Never the words: an unmet name is a spoiler.
                    IssaLog.info("ask held a streamed answer back", mapOf("unmet" to unmet.size.toString()))
                    isHeld = true
                    return@collect
                }
                met.addAll(unprobed)
            }
            shown = visible
            if (!hasAnswered && visible.isNotEmpty()) {
                hasAnswered = true
                emit(AskEvent.Phase(AskPhase.Answering))
            }
            emit(AskEvent.Partial(visible))
        }
        currentCoroutineContext().ensureActive()
        val answer = AskAnswerParser.parse(raw)
        // A generation that produced tokens but no prose is a failure, not an
        // answer. Without this the sheet drew the sources under nothing at
        // all, which is how 1.2.0 (41) shipped on the iPhone.
        //
        // The shape is logged and never the text: PRIVACY-ANDROID.md promises a
        // question and its answer are never written down.
        if (answer.text.isEmpty()) {
            IssaLog.error(
                "ask answer had no prose",
                mapOf("rawLength" to raw.graphemeCount().toString(), "citations" to answer.citations.size.toString()),
            )
            throw AskFailure.Other(AskFailure.couldNotAnswer)
        }
        // Returned rather than emitted: the answer still has to be vetted
        // against the boundary before the reader sees it as final.
        return answer
    }

    companion object {
        /**
         * Whether the model is offered the `searchBook` tool.
         *
         * Off on Android, and not by choice: ML Kit's Prompt API has no tool
         * calling. The Swift client registers it, and the 1.4.0 Ask review
         * measured Apple's model calling it 0 times in 180 asks once the
         * prompt carried the excerpts — so the excerpts are the retrieval on
         * both clients, and the no-tool passage ceiling is what a reader meets
         * here.
         */
        const val usesSearchTool = false

        /**
         * The engine a reader's question is answered by — the one place it is
         * built, so the app and the regression run cannot drift apart. Per
         * question, because on a platform with tools the tool captures the book
         * and the boundary; here it builds the same engine every time, with no
         * tool, which [usesSearchTool] says.
         */
        @Suppress("UNUSED_PARAMETER")
        fun forQuestion(
            model: AnswerModel,
            store: AskIndexStore,
            bookUuid: String,
            boundary: ReadingBoundary,
            turnstile: AskTurnstile = AskTurnstile(),
        ): AskEngine = AskEngine(model = model, store = store, tools = emptyList(), turnstile = turnstile)

        /**
         * Whether "Who is X's brother?" may be answered from the book's own
         * sentence without a model call. A kill switch, not a choice: if the
         * table ever answers something it should have declined, this is the
         * one line that turns it off.
         */
        internal const val usesKinshipFastPath = true

        /**
         * Whether the model may sample rather than take the likeliest token. A
         * kill switch in the same spirit, false until a measurement says
         * otherwise: greedy is what makes two identical asks identical.
         */
        const val usesNucleusSampling = false
        internal const val nucleusThreshold = 0.9
        internal const val nucleusTemperature = 0.3

        /**
         * The seed that makes a sampled answer repeatable: the question, the
         * book, and the place in it — exactly the three things that make two
         * asks "the same ask" to a reader. Separated by a byte that appears in
         * no question and no uuid, or ("ab", "c") and ("a", "bc") would seed
         * the same. FNV-1a, as the Swift client hashes it.
         */
        internal fun seed(question: String, bookUuid: String, boundary: ReadingBoundary): ULong =
            Fnv1a.hash("$question\u0001$bookUuid\u0001${boundary.spineIndex}\u0001${boundary.charOffset}")

        /**
         * Excerpts by the ordinal they were numbered with, one-based — the one
         * place the numbering convention is written down.
         */
        internal fun numbered(passages: List<Passage>): Map<Int, Passage> =
            passages.withIndex().associate { (index, passage) -> index + 1 to passage }

        /**
         * Each excerpt's place in the ranker's sort, for the sources row to
         * pick the strongest three with. Keyed by passage rather than by
         * ordinal; the better of two priorities wins when one passage was
         * ranked twice.
         */
        internal fun priorities(ranked: List<PassageRanker.Ranked>): Map<Passage, Int> {
            val priorities = HashMap<Passage, Int>()
            for (piece in ranked) priorities.merge(piece.passage, piece.priority, ::minOf)
            return priorities
        }

        /**
         * Capitalised words in an answer that a sentence did not have to
         * capitalise.
         *
         * Deliberately the same crude test as [QueryTerms.nameCandidates], and
         * for the same reason: the names readers get spoiled by are invented
         * ones no general-purpose tagger knows. Over-catching costs a "the
         * story hasn't revealed that yet" for an answer that was fine;
         * under-catching costs the one promise the feature makes.
         *
         * Every sentence starts with a capital, so exempting them all exempted
         * the spoiler: "Aldric dies. Ryn escapes." would have returned nothing.
         * A word that opens a sentence is exempt only when it is a closed-class
         * function word ([QueryTerms.sentenceOpeners]).
         *
         * **Not a name finder.** The only safe use of one here would be as a
         * positive exemption — "this is a place" — which opens a hole precisely
         * where place names are the spoiler: "Mordor lies to the east."
         *
         * Public, unlike the rest of the engine's arithmetic, because the
         * real-model suites in `:ask-android` run on a device in another module
         * and check the model's answers with exactly this test.
         */
        fun unvettedNames(answer: String): List<String> {
            val candidates = HashSet<String>()
            // The first word of the answer opens a sentence like any other.
            var opensSentence = true
            for (word in answer.splitOnWhitespace()) {
                // Closing marks first: `said "Hello."` ends a sentence, and its
                // last character is a quotation mark.
                val closed = word.trimmingCharacters(CLOSING_MARKS)
                val bare = word.trimmingNonLetters()
                val endsSentence = endsSentence(closed, bare)
                val opening = opensSentence
                opensSentence = endsSentence

                val initial = bare.firstCodePoint ?: continue
                if (!isSwiftUppercase(initial) || bare.graphemeCount() <= 2) continue
                if (bare.lowercasedSwift() in QueryTerms.capitalisedNonNames) continue
                // The exemption is conditional: only a closed-class function
                // word is capitalised for grammar rather than for a person.
                if (opening && bare.lowercasedSwift() in QueryTerms.sentenceOpeners) continue
                // Possessive-stripped, so "Dask's" is checked against the index
                // as `dask` — the word the book actually contains.
                for (token in QueryTerms.tokens(bare).map(QueryTerms::strippingPossessive)) {
                    if (token.graphemeCount() > 2) candidates.add(token)
                }
            }
            return candidates.sorted()
        }

        /**
         * Whether this word closes a sentence, so the next one opens one.
         *
         * An honorific does not, even though it ends in a full stop. "She met
         * Mr. Darcy at the ball." exempted Darcy outright while `Mr.` looked
         * like the end of a sentence. A sentence that genuinely ends on an
         * honorific loses the exemption for the word after it, which is the
         * conservative direction.
         */
        internal fun endsSentence(closed: String, bare: String): Boolean {
            val last = closed.lastOrNull() ?: return false
            if (last !in SENTENCE_ENDERS) return false
            return bare.lowercasedSwift() !in NameFinder.honorifics
        }

        /**
         * No colon and no semicolon: both introduce a continuation rather than
         * close a sentence, and while they were here `The note said: Aldric is
         * alive.` exempted the name the note was about.
         */
        internal val SENTENCE_ENDERS: Set<Char> = setOf('.', '!', '?')

        /** Quotation marks and brackets, which sit outside the full stop. */
        internal const val CLOSING_MARKS = "\"'”’)]}»›"

        /**
         * All of them, then the best half, then the best two — strictly
         * decreasing, and each attempt a subset of the one before it.
         *
         * A step that is not smaller than the one before it would fail in
         * exactly the same way and cost the reader another five seconds to be
         * told so. The best rather than the first: a `prefix` of a book-ordered
         * list threw away the end of what the reader had read.
         */
        internal fun attempts(ranked: List<PassageRanker.Ranked>): List<List<PassageRanker.Ranked>> {
            if (ranked.isEmpty()) return listOf(ranked)
            val sizes = ArrayList<Int>()
            for (size in listOf(ranked.size, ranked.size / 2, 2)) {
                if (size < 1) continue
                val last = sizes.lastOrNull()
                if (last != null && size >= last) continue
                sizes.add(size)
            }
            return sizes.map { PassageRanker.best(ranked, it) }
        }

        /**
         * The answer so far, up to its last whole word.
         *
         * A snapshot ends wherever the model's last token did, which is as
         * often the middle of a word as the end of one; the whitespace after a
         * word arrives with the next token. Nothing before the first whitespace
         * is whole, so nothing is shown until there is.
         */
        internal fun wholeWords(raw: String): String {
            val last = raw.indexOfLast { isSwiftWhitespace(it.code) }
            return if (last < 0) "" else raw.substring(0, last)
        }

        /**
         * The catch-all. Everything the model can say about why it did not
         * answer has already been turned into an [AskFailure] by whichever
         * model said it — this never leaks a framework error string into the
         * sheet.
         */
        internal fun failure(error: Throwable): AskFailure {
            if (error is AskFailure) return error
            IssaLog.error("ask failed", mapOf("kind" to error.javaClass.simpleName))
            return AskFailure.Other("Something went wrong answering that. Try again.")
        }

        /** The sentinel answer, with no sources: nothing was composed, so nothing is shown in proof. */
        private fun withheld(): AskAnswer = AskAnswer(
            text = AskAnswerParser.notYetSentinel,
            citations = emptyList(),
            notYetRevealed = true,
            origin = AskAnswer.Origin.WITHHELD,
        )
    }
}
