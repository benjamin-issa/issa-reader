package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.core.diagnostics.IssaLog
import kotlinx.coroutines.CancellationException

/**
 * The one way a model is allowed to ask for more of the book, in terms any
 * model can call: one string in, numbered excerpts out. Swift's
 * `BookSearchTool`, offered on Android to a reader's own provider only —
 * Gemini Nano cannot call tools.
 *
 * Everything about its shape is a bound rather than a capability:
 *
 * - **The book and the boundary are captured at construction**, from the same
 *   values the first-pass retrieval used, and every call goes through the same
 *   [AskRetriever] with the same SQL clause. There is no path through this
 *   type that can reach a passage the reader has not read, or a passage from a
 *   book they are not reading, whatever the model asks for.
 * - **A few calls**, after which it says so in words the model can act on.
 * - **A token cap on what comes back**, because the answer still has to fit
 *   in the window beside what is already there.
 * - **Calls run one at a time.** A model that issues two searches in one turn
 *   would otherwise have both read the same next ordinal before either
 *   recorded what it emitted, numbering two different excerpts `[7]`. The
 *   wires also ask for one call per turn; this makes the numbering right
 *   whatever a model does.
 *
 * @param render applied to the excerpts' text before the model sees it: a
 *   reader's own key gets it scrubbed of the book's name, as the prompt is.
 */
class BookSearchTool(
    private val store: AskIndexStore,
    private val bookUuid: String,
    private val boundary: ReadingBoundary,
    private val render: AskPromptBuilder.Render = AskPromptBuilder.asStored,
    override val callLimit: Int = 2,
    /** How many passages one search may return, before the token cap trims it further. */
    private val passageLimit: Int = DEFAULT_PASSAGE_LIMIT,
    /** Roughly how many tokens of them, by the builder's character estimate. */
    private val tokenCap: Int = DEFAULT_TOKEN_CAP,
) : AskTool {
    override val name: String = "searchBook"

    /**
     * Written in the second person and stating the bound, because the model
     * reads this as instructions and behaves better when it knows the limit
     * before it hits it.
     */
    override val toolDescription: String
        get() = if (callLimit == 2) DESCRIPTION else DESCRIPTION.replace("You may search at most twice.", "You may search at most $callLimit times.")

    override val parametersJsonSchema: String get() = PARAMETERS_JSON_SCHEMA

    private val budget = SearchBudget()

    /** One call at a time, so each numbers from where the last one stopped. */
    private val gate = AskTurnstile()

    override suspend fun beginGeneration(numberingFrom: Int) = budget.begin(numberingFrom)

    override suspend fun passagesShown(): Map<Int, Passage> = budget.shown()

    override suspend fun call(query: String): String = gate.withTurn { search(query) }

    private suspend fun search(query: String): String {
        val firstOrdinal = budget.spend(callLimit) ?: return EXHAUSTED
        // The same retrieval the first pass used, with the book's own names.
        // No fast path: the model has already been called, and a finished
        // sentence is not a search result. No recency padding: the pages just
        // read are already in the prompt, and a search should return what
        // matched it.
        val retriever = AskRetriever(store, bookUuid, boundary, allowsFastPath = false, recencyPassages = 0)
        val retrieval = try {
            retriever.retrieve(query, passageLimit)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
        // The best, not the first: retrieval hands these back in book order.
        val ranked = (retrieval as? AskRetriever.Retrieval.Found)?.let { PassageRanker.best(it.ranked, passageLimit) } ?: emptyList()
        // Counts only, never the query.
        IssaLog.debug("ask tool searched", mapOf("found" to ranked.size.toString()))
        if (ranked.isEmpty()) return NO_MATCHES
        val (text, shown) = excerpts(ranked.map { it.passage }, firstOrdinal, render, tokenCap)
        budget.record(shown)
        return text
    }

    companion object {
        const val DESCRIPTION =
            "Search the part of the book the reader has already read for more excerpts. " +
                "Use this only when the excerpts you were given do not answer the question. " +
                "You may search at most twice."

        /** The argument's description. */
        const val QUERY_DESCRIPTION = "Words to look for, such as a character's name or a thing that happened."

        /**
         * The tool's one argument as a JSON schema. Strict-mode shaped
         * (`additionalProperties: false`, every property required), which both
         * providers accept.
         */
        const val PARAMETERS_JSON_SCHEMA =
            "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"$QUERY_DESCRIPTION\"}}," +
                "\"required\":[\"query\"],\"additionalProperties\":false}"

        /**
         * What the model is told once it has spent its searches. Phrased as an
         * instruction rather than an error, so the model answers from what it
         * has.
         */
        const val EXHAUSTED = "No more searches are available; answer from what you have."
        internal const val NO_MATCHES = "Nothing in the part of the book the reader has read matches that."

        const val DEFAULT_TOKEN_CAP = 300
        const val DEFAULT_PASSAGE_LIMIT = 2

        /** The search a reader's own provider gets: four searches of up to eight passages, about 3,000 tokens each. */
        const val PROVIDER_CALLS = 4
        const val PROVIDER_PASSAGES = 8
        const val PROVIDER_TOKENS = 3_000

        /**
         * Numbered excerpts in the prompt's plain format, continuing its
         * numbering, capped at roughly [tokenCap]. The last passage is cut at a
         * word rather than dropped when it is the only one.
         *
         * @return the text, and the passages that made it into it by ordinal.
         */
        internal fun excerpts(
            passages: List<Passage>,
            numberingFrom: Int,
            render: AskPromptBuilder.Render = AskPromptBuilder.asStored,
            tokenCap: Int = DEFAULT_TOKEN_CAP,
        ): Pair<String, Map<Int, Passage>> {
            val lines = ArrayList<String>()
            val shown = LinkedHashMap<Int, Passage>()
            var spent = 0
            for ((offset, passage) in passages.withIndex()) {
                val ordinal = numberingFrom + offset
                val head = "[$ordinal] (Section ${passage.spineIndex + 1}) "
                val room = tokenCap - spent - AskPromptBuilder.estimatedTokens(head)
                if (room <= 20 && lines.isNotEmpty()) break
                val body = truncated(render.text(passage), maxOf(room, 20))
                lines.add(head + body)
                shown[ordinal] = passage
                spent += AskPromptBuilder.estimatedTokens(head + body)
                if (spent >= tokenCap) break
            }
            return lines.joinToString("\n\n") to shown
        }

        internal fun truncated(text: String, tokens: Int): String {
            if (AskPromptBuilder.estimatedTokens(text) <= tokens) return text
            val characters = (tokens * AskPromptBuilder.Budget.charactersPerToken).toInt()
            val clipped = text.graphemePrefix(maxOf(characters, 1))
            val lastSpace = clipped.lastIndexOf(' ')
            return if (lastSpace < 0) clipped else clipped.substring(0, lastSpace) + "…"
        }
    }
}

/**
 * The tool's per-generation state: how many calls are spent, where the next
 * one numbers from, and every excerpt handed over. Cleared by [begin], because
 * a context-window retry is a fresh generation with a different prompt.
 */
private class SearchBudget {
    private var used = 0
    private var nextOrdinal = 1
    private val shown = LinkedHashMap<Int, Passage>()

    @Synchronized
    fun begin(numberingFrom: Int) {
        used = 0
        nextOrdinal = maxOf(numberingFrom, 1)
        shown.clear()
    }

    /** The ordinal to number this call's excerpts from, or null when the budget is spent. */
    @Synchronized
    fun spend(limit: Int): Int? {
        if (used >= limit) return null
        used += 1
        return nextOrdinal
    }

    /** What a call actually emitted, so the next one numbers from where it stopped. */
    @Synchronized
    fun record(excerpts: Map<Int, Passage>) {
        shown.putAll(excerpts)
        nextOrdinal += excerpts.size
    }

    @Synchronized
    fun shown(): Map<Int, Passage> = LinkedHashMap(shown)
}
