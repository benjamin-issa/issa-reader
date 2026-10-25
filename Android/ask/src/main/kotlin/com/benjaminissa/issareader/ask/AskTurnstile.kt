package com.benjaminissa.issareader.ask

import kotlinx.coroutines.sync.Mutex
import java.util.concurrent.atomic.AtomicInteger

/**
 * One turn at the on-device model, for the whole process.
 *
 * There is one model on the device, so the constraint belongs to the process
 * rather than to an engine — and while it was engine state it serialised
 * nothing at all: the app builds a fresh [AskEngine] per question, so two books
 * meant two engines, two turnstiles and two concurrent generations. The reader
 * who asked about a second book was told the model was busy for a question
 * that should have queued.
 *
 * A reader who asks again before the first answer lands should get the second
 * answer rather than an error, so the second question waits rather than
 * racing. A [Mutex] is that queue: it is fair, so waiters are let through in
 * the order they arrived, and a waiter whose own question is cancelled leaves
 * the queue rather than holding its place.
 */
class AskTurnstile {
    private val mutex = Mutex()
    private val queued = AtomicInteger(0)

    /**
     * Runs [body] holding the turn, and releases it whether it returns or
     * throws.
     *
     * The release is written here, once, rather than at the call sites: a
     * forgotten release wedges every later question in the process, with no
     * error and nothing in the log.
     */
    suspend fun <T> withTurn(body: suspend () -> T): T {
        queued.incrementAndGet()
        try {
            mutex.lock()
        } finally {
            queued.decrementAndGet()
        }
        try {
            return body()
        } finally {
            mutex.unlock()
        }
    }

    /**
     * Runs [body] only if the turn is free, and skips it otherwise.
     *
     * For work that is pointless once it has to wait. [AskEngine.prewarm]
     * loads the model so the reader's first question is faster; a prewarm that
     * queues behind a generation would be loading what that generation has
     * already loaded, twenty seconds after it stopped mattering.
     *
     * @return whether [body] ran.
     */
    suspend fun ifFree(body: suspend () -> Unit): Boolean {
        if (!mutex.tryLock()) return false
        try {
            body()
        } finally {
            mutex.unlock()
        }
        return true
    }

    /**
     * How many callers are queued for the turn.
     *
     * For a test to see that a question is *waiting*, rather than infer it from
     * how far a sleep happened to let it get. The holder of the turn is not
     * counted, and neither is a caller that took a free turn at once — it is
     * counted for the instant it takes to lock, which a test polling for a
     * waiter cannot mistake for one.
     */
    val waiting: Int get() = if (mutex.isLocked) maxOf(0, queued.get()) else 0
}
