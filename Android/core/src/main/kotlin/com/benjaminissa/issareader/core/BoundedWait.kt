package com.benjaminissa.issareader.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.time.Duration

/**
 * Waits for some work, or for a deadline, whichever comes first — and never
 * cancels the work.
 *
 * For work a caller cannot cancel and must not be held by: the work runs in a
 * coroutine of its own, outside the caller's scope, and goes on after the
 * wait ends. Structured concurrency cannot do this, because a parent waits for
 * every child, so the loser has to be cancelled — and a child stuck in a call
 * that ignores cancellation holds the parent as surely as awaiting it
 * directly, while a cancelled request is one that was never sent.
 *
 * One for the whole app. Sign-out's token revoke (`Session`) and the search
 * index's clear on an account's departure each had a private copy, and the
 * copies had already drifted: only one cancelled its timer when the work won,
 * so every sign-out left a three-second sleep running to a no-op.
 *
 * The caller's own cancellation ends its wait, as any suspension's would; it
 * still never reaches the work.
 */
object BoundedWait {
    /** Where the work and the timer run: detached from every caller. */
    private val detached = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** @return whether the work finished before the deadline. */
    suspend fun run(limit: Duration, work: suspend () -> Unit): Boolean =
        run(limit, sleep = { delay(it) }, work = work)

    /**
     * The same, with the deadline's sleep handed in, so a test can see the
     * timer let go of once the work has won.
     */
    internal suspend fun run(limit: Duration, sleep: suspend (Duration) -> Unit, work: suspend () -> Unit): Boolean {
        // Completed exactly once, whichever side gets there first.
        val outcome = CompletableDeferred<Boolean>()
        val timer = detached.launch {
            runCatching { sleep(limit) }
            outcome.complete(false)
        }
        detached.launch {
            work()
            outcome.complete(true)
            timer.cancel()
        }
        return outcome.await()
    }
}
