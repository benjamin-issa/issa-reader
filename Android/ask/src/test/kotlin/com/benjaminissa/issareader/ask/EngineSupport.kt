package com.benjaminissa.issareader.ask

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import java.util.Collections

/** What a run produced: every event, and the failure it ended on, if any. */
internal data class Drained(val events: List<AskEvent>, val failure: Throwable?)

/** Collects a whole run, recording each event as it lands when [into] is given, so a test can wait on one mid-stream. */
internal suspend fun drain(flow: Flow<AskEvent>, into: Collected? = null): Drained {
    val events = Collections.synchronizedList(ArrayList<AskEvent>())
    return try {
        flow.collect { event ->
            events.add(event)
            into?.append(event)
        }
        Drained(events.toList(), null)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (failure: Throwable) {
        Drained(events.toList(), failure)
    }
}

internal fun partials(events: List<AskEvent>): List<String> = events.mapNotNull { (it as? AskEvent.Partial)?.text }

internal fun answer(events: List<AskEvent>): AskAnswer? = events.mapNotNull { (it as? AskEvent.Answered)?.answer }.lastOrNull()

internal val thinking: AskEvent = AskEvent.Phase(AskPhase.Thinking)
internal val retrieving: AskEvent = AskEvent.Phase(AskPhase.Retrieving)
internal val answering: AskEvent = AskEvent.Phase(AskPhase.Answering)

/** Events as the consumer actually saw them, and a way to wait for one to land. */
internal class Collected {
    private val lock = Any()
    private val seen = ArrayList<AskEvent>()
    private val thinkingSeen = CompletableDeferred<Unit>()
    private val partialSeen = CompletableDeferred<Unit>()

    val events: List<AskEvent> get() = synchronized(lock) { seen.toList() }

    fun append(event: AskEvent) {
        synchronized(lock) { seen.add(event) }
        if (event == thinking) thinkingSeen.complete(Unit)
        if (event is AskEvent.Partial) partialSeen.complete(Unit)
    }

    /** Until the engine says it is about to ask the model. */
    suspend fun waitForThinking() = thinkingSeen.await()

    suspend fun waitForAPartial() = partialSeen.await()
}
