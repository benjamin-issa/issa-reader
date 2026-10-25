package com.benjaminissa.issareader.ask

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlin.math.ceil

/**
 * A model that answers whatever it was told to answer.
 *
 * It ships in the library rather than living in the tests on purpose. The
 * spoiler defence — the boundary, the trimming, the short-circuit, the context
 * retry, the serialising — is the part of this feature that has to be
 * *proved*, and none of it can be proved against a real model whose output is
 * not a function of its input. Everything the engine does is therefore
 * asserted against this, and the real model is checked separately for the one
 * thing only it can show: that a sensible question gets a sensible answer.
 *
 * Thread-safe, because the tests read back what the engine sent it from a
 * coroutine that is not the engine's.
 *
 * @param turns consumed in order; the last one repeats once they run out, so a
 *   test that only cares about one answer writes one turn.
 * @param contextSize the window the engine budgets against. 4,096 is Apple's;
 *   a test that wants to force trimming passes something small.
 * @param charactersPerToken the fake tokeniser's rate, so a test can do the
 *   arithmetic in its head.
 * @param supportedLanguages null means every language, which is what a test
 *   about anything else wants.
 */
class ScriptedAnswerModel(
    turns: List<Turn> = listOf(Turn.answer("Alice followed a white rabbit down the hole.\nSources: 1")),
    override val contextSize: Int = 4_096,
    private val charactersPerToken: Int = 4,
    private val supportedLanguages: Set<String>? = null,
) : AnswerModel {
    /** One scripted reply, consumed in order. */
    data class Turn(
        /** Snapshots, each the answer *so far*, not deltas. */
        val partials: List<String> = emptyList(),
        /** Thrown instead of finishing. [AskFailure.TooMuchContext] is how a context-window retry is driven. */
        val failure: Throwable? = null,
        /**
         * Suspends after this many partials until [release] is called — what
         * makes "cancelled halfway" and "two questions at once" deterministic
         * tests rather than races against a sleep.
         */
        val holdsAfterPartials: Int? = null,
    ) {
        companion object {
            /** A turn that streams one answer, in the two snapshots a real stream would produce. */
            fun answer(text: String): Turn = Turn(partials = listOf(text.graphemePrefix(text.graphemeCount() / 2), text))
        }
    }

    /**
     * Exactly what the engine asked for, so a test can assert on what the
     * model was *told* — which is where every spoiler leak would show up.
     */
    data class Received(
        val instructions: String,
        val prompt: String,
        val toolNames: List<String>,
        val options: AskGenerationOptions,
    )

    /** For driving the engine's catch-all branch. */
    sealed class ScriptedError(message: String) : Exception(message) {
        data object Scripted : ScriptedError("scripted")
    }

    private val lock = Any()
    private val turns = turns.toList()
    private var index = 0
    private val receivedCalls = ArrayList<Received>()
    private var prewarms = 0
    private var inFlight = 0
    private var peak = 0

    /** Everything the engine sent, in order. */
    val received: List<Received> get() = synchronized(lock) { receivedCalls.toList() }

    val prewarmCount: Int get() = synchronized(lock) { prewarms }

    /**
     * The most generations that were ever in flight at once, so a turnstile
     * test can assert the thing it means: this cannot be one when the
     * serialising is broken.
     */
    val peakConcurrency: Int get() = synchronized(lock) { peak }

    // AnswerModel

    override fun answer(
        instructions: String,
        prompt: String,
        tools: List<AskTool>,
        options: AskGenerationOptions,
    ): Flow<String> = flow {
        val call = Received(instructions, prompt, tools.map { it.name }, options)
        val turn = synchronized(lock) {
            inFlight += 1
            peak = maxOf(peak, inFlight)
            receivedCalls.add(call)
            val turn = if (turns.isEmpty()) Turn.answer(AskAnswerParser.notYetSentinel) else turns[minOf(index, turns.size - 1)]
            index += 1
            turn
        }
        try {
            for ((emitted, partial) in turn.partials.withIndex()) {
                currentCoroutineContext().ensureActive()
                emit(partial)
                if (turn.holdsAfterPartials == emitted + 1) hold()
            }
            if (turn.partials.isEmpty() && turn.holdsAfterPartials != null) hold()
            turn.failure?.let { throw it }
        } finally {
            synchronized(lock) { inFlight -= 1 }
        }
    }

    override suspend fun tokenCount(text: String): Int = ceil(text.graphemeCount().toDouble() / charactersPerToken).toInt()

    override suspend fun prewarm() {
        synchronized(lock) { prewarms += 1 }
    }

    override fun supportsLanguage(bcp47: String?): Boolean {
        val supported = supportedLanguages ?: return true
        if (bcp47.isNullOrEmpty()) return true
        return bcp47.graphemePrefix(2).lowercasedSwift() in supported
    }

    // The gate

    private val holders = ArrayList<CompletableDeferred<Unit>>()
    private var holdingStarted = CompletableDeferred<Unit>()
    private var isHolding = false

    private suspend fun hold() {
        val gate = CompletableDeferred<Unit>()
        synchronized(lock) {
            isHolding = true
            holders.add(gate)
            holdingStarted.complete(Unit)
        }
        try {
            gate.await()
        } finally {
            synchronized(lock) {
                holders.remove(gate)
                if (holders.isEmpty()) isHolding = false
            }
        }
    }

    /**
     * Suspends the caller until the scripted stream has actually stopped at
     * its hold — the point at which a test knows the engine is mid-answer and
     * can cancel it, or ask a second question, without racing anything.
     */
    suspend fun waitUntilHolding() {
        val signal = synchronized(lock) { if (isHolding) null else holdingStarted } ?: return
        signal.await()
    }

    /** Lets a held stream finish. */
    fun release() {
        synchronized(lock) {
            isHolding = false
            for (holder in holders) holder.complete(Unit)
            holders.clear()
            holdingStarted = CompletableDeferred()
        }
    }
}
