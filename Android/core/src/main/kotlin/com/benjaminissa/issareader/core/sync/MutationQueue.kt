package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.instantOfEpochSeconds
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.User
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.StorytellerError
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.store.SqliteDatabase
import com.benjaminissa.issareader.core.toEpochSecondsDouble
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.time.Instant

/**
 * Writes that have not reached the server yet.
 *
 * Every change a reader makes — where they got to, which shelf a book is on,
 * what they rated it — is recorded here *before* the network is attempted, and
 * drained when there is a connection. Without it, a chapter read on a train is
 * simply lost, and a status set in a lift silently rolls back.
 *
 * Repeated positions for the same book collapse to the newest: a reader who
 * turns forty pages offline should send one position, not forty.
 *
 * Swift's actor, as a class whose state — the drain lock, the waiters, the
 * retired flag and the table — is touched only under one lock, with nothing
 * suspending while it is held.
 */
class MutationQueue(store: LibraryStore, private val io: CoroutineDispatcher = Dispatchers.IO) : AutoCloseable {
    enum class Kind(val rawValue: String) {
        POSITION("position"),
        STATUS("status"),
        RATING("rating"),
        ;

        companion object {
            fun fromRawValue(raw: String): Kind? = entries.firstOrNull { it.rawValue == raw }
        }
    }

    class Pending(
        val id: Long,
        val bookUuid: String,
        val kind: Kind,
        val payload: ByteArray,
        val createdAt: Instant,
        val attempts: Int,
    ) {
        override fun equals(other: Any?): Boolean =
            other is Pending && other.id == id && other.bookUuid == bookUuid && other.kind == kind &&
                other.payload.contentEquals(payload) && other.createdAt == createdAt && other.attempts == attempts

        override fun hashCode(): Int = id.hashCode()
    }

    /**
     * This opens a second connection to the same file [LibraryStore] already
     * has open — the queue and the catalogue live in one SQLite database, but
     * as two independent connections there is no shared in-process lock
     * between them. SQLite's default is to fail at once on a lock another
     * connection holds, so without the timeout a position write racing a
     * catalogue refresh (both routinely concurrent: the app model enqueues a
     * position from the reader while a background job calls
     * `replaceCatalogue`) fails with `SQLITE_BUSY` the instant the two
     * connections collide — and every caller of [enqueue] wraps it in a
     * `runCatching`, so the write is discarded with no error and no retry.
     * Giving this connection the same timeout [LibraryStore] already uses for
     * exactly this kind of contention turns that into a five-second wait
     * instead of a silent loss.
     */
    private val db = SqliteDatabase(store.url.path, busyTimeoutMillis = 5000)

    /**
     * The drain's bookkeeping below — whether a drain holds it, who waits,
     * whether the queue is retired — is touched only while holding this.
     *
     * Never the database. Those calls run on the main thread, and a database
     * call can sit in SQLite's five-second busy wait behind the other
     * connection: held across it, this lock froze the main thread for as long.
     * The connection serialises its own calls ([SqliteDatabase]).
     */
    private val lock = Any()

    /**
     * Whether a drain is already in flight.
     *
     * `drain()` is called from `enqueue` (so, every debounced save), from the
     * reachability hook, from the library refresh and on foreground, and it
     * had no mutual exclusion: `pending()` never marked a row in flight, so two
     * overlapping drains read the same rows and sent them twice, concurrently,
     * in no defined order. Mark a book "Reading" and immediately "Read" and the
     * two PUTs raced; whichever landed second won, so the server could end on
     * the status the reader did not choose. Both also called `recordFailure`
     * on failure, halving the effective abandon budget.
     *
     * The lock has more than one kind of holder now. A drain holds it for as
     * long as its loop runs; an exit path waits its turn for it
     * ([waitToDrain]); a pause holds it across a change of bearer
     * ([pauseDraining]), sending nothing. A drain gives it up before its next
     * row once anyone is waiting ([shouldYield]), so no holder waits behind a
     * backlog, only behind the request already in flight. Retirement never
     * takes it: it is a flag the drain reads before each row, and the lock
     * keeps passing from holder to holder on a retired queue exactly as
     * before, so no caller has to know whether it was handed a live one.
     */
    private var isDraining = false

    /**
     * Set by [retire], and never cleared. Volatile because [enqueue] reads it
     * inside its write transaction, without [lock].
     */
    @Volatile
    private var retired = false

    /** Callers waiting for the lock, handed it in order by [endDraining]. */
    private val waiters = ArrayDeque<CompletableDeferred<Unit>>()

    /**
     * Whether a drain holding the lock should stop before its next row.
     *
     * When someone is waiting — an exit path or a pause — finishing the
     * drain's snapshot first would make them wait for the whole backlog, each
     * row a request that can take the transport's whole timeout, rather than
     * for the one request in flight. Nothing is skipped by stopping: an exit
     * path reads the queue afresh when it is handed the lock, and the rows a
     * pause holds back go with the next drain after it. A retired queue's rows
     * are nobody's to send.
     */
    val shouldYield: Boolean get() = synchronized(lock) { retired || waiters.isNotEmpty() }

    /** Claims the right to drain, or declines because someone else holds it. */
    internal fun beginDraining(): Boolean = synchronized(lock) {
        if (isDraining) return false
        isDraining = true
        true
    }

    /**
     * Claims the right to drain, waiting for it if someone else holds it.
     *
     * For the exit paths — the app going to the background, the process
     * ending — and for [pauseDraining], which waits in the same line; nothing
     * else. [beginDraining] declining is right for every ordinary caller: the
     * rows it would have sent are already in flight and the next enqueue
     * drains again. On the way out there is no next enqueue. The first version
     * of the lock made flushing the open readers a silent no-op whenever a
     * background drain happened to be blocked on a slow POST, which undid the
     * three exit paths added in the same branch for exactly that flush.
     *
     * The lock is handed over directly rather than released and re-taken, so a
     * waiter cannot lose it to a [beginDraining] that arrives in between — and
     * the wait is not cancellable, as Swift's continuation is not, because a
     * waiter that walked away would be handed a lock nobody gives back.
     *
     * An exit path handed the lock with a pause already in line behind it
     * sends nothing: its drain yields before the first row as before any other
     * ([shouldYield]) and passes the lock straight on. Its rows stay queued for
     * the first drain after the pause.
     */
    internal suspend fun waitToDrain() {
        val waiter = synchronized(lock) {
            if (!isDraining) {
                isDraining = true
                return
            }
            CompletableDeferred<Unit>().also { waiters.addLast(it) }
        }
        withContext(NonCancellable) { waiter.await() }
    }

    internal fun endDraining() {
        val next = synchronized(lock) {
            if (waiters.isNotEmpty()) {
                // Still held — by the waiter now.
                waiters.removeFirst()
            } else {
                isDraining = false
                null
            }
        }
        next?.complete(Unit)
    }

    /**
     * Takes the drain lock and keeps it until [resumeDraining].
     *
     * For the moment a bearer changes hands. A drain reads the token afresh
     * for every request, so a sign-in that swaps it under a running drain
     * sends the rows that drain has left — the departed account's — with the
     * arriving account's bearer, and a drain that starts during the swap does
     * the same from the top. Holding the lock across the swap makes that
     * impossible rather than unlikely: no drain can start, and the one in
     * flight finishes its current request and stops, because it yields to a
     * waiter before each row. The wait is one request at most, never the
     * backlog.
     *
     * Waits in line with the exit paths and is handed the lock directly, so
     * nothing can slip in between the drain stopping and the pause holding.
     */
    suspend fun pauseDraining() = waitToDrain()

    /**
     * Gives back the lock [pauseDraining] took, and only that: calling it
     * without a pause would release a drain's lock from under it. Nothing
     * drains on resuming; the rows the pause held back go with whatever drain
     * is triggered next. Harmless on a retired queue, which passes the lock on
     * as a live one does.
     */
    fun resumeDraining() = endDraining()

    /** What [enqueue] throws once the queue is retired. */
    class Retired : Exception("the mutation queue is retired")

    /**
     * Stops this queue for good: every later [enqueue] throws [Retired], and no
     * drain sends another row — the one in flight stops before its next.
     *
     * For an account switch. The rows belong to the departed account and the
     * app is about to empty the table, but emptying it is not enough on its
     * own: a write already on its way into the queue could insert its row
     * after the DELETE, where the arriving account's drain would find it and
     * send it under the new bearer. Retiring first closes that. [enqueue]
     * reads the flag and writes its row under one lock, with nothing between,
     * so an insert either ran before `retire()` — and so before any DELETE the
     * caller issues once `retire()` has returned — or runs after it and is
     * refused. Which of the two a write already on its way in gets is not
     * promised, and it does not need to be: either way nothing lands after the
     * DELETE, and a refused write was the departed account's.
     *
     * The "one lock" is the database's own write lock. [enqueue] reads the flag
     * inside its write transaction, and the caller's DELETE, on any connection
     * to the file, is a write that has to wait for that transaction to end: a
     * write whose transaction began before the flag was set inserts first and
     * is deleted with the rest, and one that begins after reads the flag and is
     * refused. So retiring never waits for a write, even one stuck in SQLite's
     * busy wait.
     *
     * Only a flag. It never waits for the drain lock, so it is safe while a
     * pause holds it, and it deletes nothing: the rows are the caller's to
     * clear.
     */
    fun retire() {
        synchronized(lock) { retired = true }
    }

    /**
     * Closes this queue's connection to the database file. Swift's queue
     * closes its own when it is released; a Kotlin one is closed by whoever
     * made it, after the last drain.
     */
    override fun close() = db.close()

    /**
     * Records an intent. Positions replace any earlier pending position for the
     * same book; status and rating likewise, since only the latest matters.
     *
     * @param supersedes a caller-supplied ordering value — for a position, the
     *   timestamp the server will compare. A pending write is replaced only by
     *   one at least as new; an older one is dropped rather than allowed to
     *   overwrite it. Without this, a write generated out of order erased a
     *   good one that had not yet drained, and the queue was the only copy of
     *   it. `null` keeps the unconditional collapse, which is right for status
     *   and rating: there the newest call always wins by definition.
     * @return whether anything was recorded.
     * @throws Retired once [retire] has run, before touching the table.
     */
    suspend fun enqueue(kind: Kind, bookUuid: String, payload: ByteArray, supersedes: Double? = null): Boolean =
        withContext(io) {
            if (retired) throw Retired()
            db.write { db ->
                // Again inside the transaction, which is what retirement's
                // promise rests on (see [retire]); the check above only
                // spares a retired queue the wait for the write lock.
                if (retired) throw Retired()
                val existing = db.queryOne(
                    "SELECT ordering, attempts, createdAt, payload FROM mutation WHERE bookUUID = ? AND kind = ?",
                    bookUuid, kind.rawValue,
                ) { row ->
                    Existing(
                        ordering = row.doubleOrNull("ordering"),
                        attempts = row.long("attempts").toInt(),
                        createdAt = row.double("createdAt"),
                        payload = row.blob("payload"),
                    )
                }
                val held = heldOrdering(existing)
                if (supersedes != null && held != null && supersedes < held) {
                    // The queued write is newer than this one. Keeping it is
                    // the whole point: it may be the only remaining copy of
                    // where the reader actually is.
                    return@write false
                }
                // The replacement inherits the failures and the age of what
                // it replaces. With a fresh count on every collapse, a
                // position the server kept refusing was re-queued every page
                // turn as a brand-new item and could never reach the abandon
                // limit.
                //
                // Its place in the drain is its own, though. `updatedAt` is
                // now, and the drain sends in that order — the order the
                // reader made the writes in. Going by `createdAt`, which the
                // collapse keeps, a status chosen between two offline page
                // turns was sent after the second: the server's own rule ran
                // on the position before the reader's choice arrived, and the
                // book ended on a different status than it would have with a
                // connection.
                val now = Instant.now().toEpochSecondsDouble()
                val attempts = existing?.attempts ?: 0
                val createdAt = existing?.createdAt ?: now
                db.execute("DELETE FROM mutation WHERE bookUUID = ? AND kind = ?", bookUuid, kind.rawValue)
                db.execute(
                    "INSERT INTO mutation (bookUUID, kind, payload, createdAt, updatedAt, attempts, ordering) " +
                        "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    bookUuid, kind.rawValue, payload, createdAt, now, attempts, supersedes,
                )
                true
            }
        }

    private class Existing(val ordering: Double?, val attempts: Int, val createdAt: Double, val payload: ByteArray)

    /**
     * How new the queued row is, from its column or from its payload.
     *
     * The guard above used to read only the `ordering` column, which silently
     * skips the whole check when that column is NULL — and it is NULL for every
     * row written before the `v4-mutation-ordering` migration, which added the
     * column with no backfill. A reader who queued a position offline on the
     * old build, upgraded, and took an out-of-order write before the queue
     * drained had that row deleted and replaced by the older one. The doc two
     * lines up calls it possibly the only remaining copy of where the reader
     * is.
     *
     * The timestamp is already inside the encoded payload, so a row from before
     * the migration can still say how new it is.
     */
    private fun heldOrdering(row: Existing?): Double? {
        if (row == null) return null
        row.ordering?.let { return it }
        return runCatching {
            IssaJson.decodeFromString(MutationDrain.PositionPayload.serializer(), row.payload.decodeToString()).timestamp
        }.getOrNull()
    }

    private suspend fun <T> writing(block: (SqliteDatabase.Access) -> T): T = withContext(io) { db.write(block) }

    private suspend fun <T> reading(block: (SqliteDatabase.Access) -> T): T = withContext(io) { db.read(block) }

    /**
     * Blanks the ordering column, to stand in for a row written before the v4
     * migration added it. Tests only — there is no other way to produce a
     * pre-migration row against a freshly-migrated database.
     */
    internal suspend fun clearOrderingForTesting(bookUuid: String) {
        writing { db -> db.execute("UPDATE mutation SET ordering = NULL WHERE bookUUID = ?", bookUuid) }
    }

    /**
     * Inserts a row with the statement 1.3.0 used, which names no `updatedAt`.
     * Tests only: it stands for an older build writing to this file after a
     * downgrade, which is the one way such a row arises.
     */
    internal suspend fun enqueueAsOlderBuildForTesting(kind: Kind, bookUuid: String, payload: ByteArray, createdAt: Double) {
        writing { db ->
            db.execute(
                "INSERT INTO mutation (bookUUID, kind, payload, createdAt, attempts, ordering) VALUES (?, ?, ?, ?, ?, ?)",
                bookUuid, kind.rawValue, payload, createdAt, 0, null,
            )
        }
    }

    /**
     * Everything waiting, in the order to send it: when each write was last
     * made, oldest first. A row an older build wrote after a downgrade has no
     * `updatedAt`, and its queued time stands in; `id`, which only grows,
     * settles a tie in the order the rows went in.
     */
    suspend fun pending(): List<Pending> = reading { db ->
        db.query("SELECT * FROM mutation ORDER BY COALESCE(updatedAt, createdAt) ASC, id ASC") { row ->
            val kind = Kind.fromRawValue(row.string("kind")) ?: return@query null
            Pending(
                id = row.long("id"),
                bookUuid = row.string("bookUUID"),
                kind = kind,
                payload = row.blob("payload"),
                createdAt = instantOfEpochSeconds(row.double("createdAt")),
                attempts = row.long("attempts").toInt(),
            )
        }.filterNotNull()
    }

    suspend fun remove(id: Long) {
        writing { db -> db.execute("DELETE FROM mutation WHERE id = ?", id) }
    }

    /**
     * Records a failed attempt, and gives up after enough of them.
     *
     * A write the server keeps refusing — a book deleted server-side, a
     * permission revoked — must not be retried forever, or it blocks every
     * later write behind it.
     */
    suspend fun recordFailure(id: Long, abandonAfter: Int = 8): Boolean = writing { db ->
        db.execute("UPDATE mutation SET attempts = attempts + 1 WHERE id = ?", id)
        val attempts = db.queryOne("SELECT attempts FROM mutation WHERE id = ?", id) { it.long(0).toInt() } ?: 0
        if (attempts >= abandonAfter) {
            db.execute("DELETE FROM mutation WHERE id = ?", id)
            true
        } else {
            false
        }
    }

    suspend fun count(): Int = reading { db -> db.queryOne("SELECT COUNT(*) FROM mutation") { it.long(0).toInt() } ?: 0 }

    suspend fun removeAll() {
        writing { db -> db.execute("DELETE FROM mutation") }
    }
}

/** Sends what the queue holds, and keeps what it cannot send. */
class MutationDrain(private val queue: MutationQueue, private val client: ApiClient) {
    @Serializable
    data class PositionPayload(val locator: ReadiumLocator, val timestamp: Double)

    @Serializable
    data class StatusPayload(val status: String)

    @Serializable
    data class RatingPayload(val rating: Double?)

    /**
     * Attempts every pending write, oldest first.
     *
     * Stops before its next row, the first included, once someone is waiting
     * for the lock — an exit path or a pause — or the queue is retired
     * ([MutationQueue.shouldYield]). A call can therefore return with rows
     * still pending: they go with the next drain, or, on a retired queue, with
     * none.
     *
     * A row refused with a 404 or a 403 is dropped only once the same drain
     * has seen Storyteller itself answer; until then it stays queued. See
     * [settle].
     *
     * @param waitingForInFlight wait for a drain already running rather than
     *   declining. Only the exit paths pass `true`; see
     *   [MutationQueue.waitToDrain].
     * @return how many were accepted.
     */
    suspend fun drain(waitingForInFlight: Boolean = false): Int {
        // One drain at a time. A second caller returning 0 immediately is
        // correct because the drain it declines to sends what that caller came
        // with: the running one reads the queue again after each pass and goes
        // on while rows it has not tried are waiting — so a write enqueued
        // mid-drain (whose own drain is this decline) goes with it. On the way
        // out the waiting form is used instead, because the running drain
        // yields its remaining rows to whoever waits.
        if (waitingForInFlight) {
            queue.waitToDrain()
        } else if (!queue.beginDraining()) {
            return 0
        }
        // Released before returning, whatever happens in between — including a
        // cancellation, which would otherwise leave the lock held for good.
        try {
            return drainHoldingTheLock()
        } finally {
            queue.endDraining()
        }
    }

    private class Refusal(val item: MutationQueue.Pending, val error: StorytellerError)

    private suspend fun drainHoldingTheLock(): Int {
        var sent = 0
        // Rows refused with a 404 or a 403, held until this drain knows who
        // refused them. See `settle`.
        val refused = mutableListOf<Refusal>()
        // Whether the loop reached the end of its rows, rather than stopping at
        // a broken connection, a 401 or someone waiting for the lock.
        var reachedTheEnd = true
        // Every row this drain has had a go at, so a pass over the queue read
        // again sends only what arrived since. Ids only grow (the column is
        // AUTOINCREMENT), and a collapse is a DELETE and an INSERT, so a write
        // that replaced one in flight is a new id here.
        val tried = mutableSetOf<Long>()

        // Pass after pass, until one finds nothing new. The rows are read once
        // per pass, not once per drain: a drain declined while this one runs
        // (`beginDraining()`) is relying on this one to send its row, and with
        // a single read a rating tapped 4 then 5 inside one round trip left the
        // server at 4 and the screen at 5 until some unrelated drain came by.
        // Each further pass needs a row enqueued during the last one, so this
        // ends as soon as the reader stops writing for one round trip.
        passes@ while (reachedTheEnd) {
            val pending = try {
                queue.pending()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                break
            }
            val fresh = pending.filter { it.id !in tried }
            if (fresh.isEmpty()) break

            for (item in fresh) {
                // Before every row, not once: a pause taken mid-drain waits for
                // the request in flight, not for everything behind it, and a
                // queue retired mid-drain sends nothing more.
                if (queue.shouldYield) {
                    reachedTheEnd = false
                    break
                }
                tried.add(item.id)
                try {
                    send(item)
                    runCatching { queue.remove(item.id) }
                    sent += 1
                } catch (e: CancellationException) {
                    throw e
                } catch (_: StorytellerError.PositionConflict) {
                    // The server has something newer. Ours is obsolete, not
                    // failed.
                    //
                    // Logged, because this and the refusals below are where a
                    // write is thrown away on the server's word, and they were
                    // the only ones that said nothing — so a server that
                    // refused every position looked exactly like a client that
                    // never sent one.
                    IssaLog.info("mutation superseded by server", mapOf("kind" to item.kind.rawValue, "book" to item.bookUuid))
                    runCatching { queue.remove(item.id) }
                } catch (_: StorytellerError.NotAuthenticated) {
                    // Not this item's problem — the whole session is bad, and
                    // every later item would fail identically. Keeping it
                    // queued, rather than falling into the not-retryable branch
                    // below and discarding it, means a write that would have
                    // succeeded once signed in again is not lost. Stopping the
                    // loop is what keeps an expired token from silently
                    // emptying the entire backlog in one pass — the removal
                    // below has no `break`, so before this case existed the
                    // first 401 deleted everything behind it too.
                    reachedTheEnd = false
                    break
                } catch (e: StorytellerError) {
                    if (e is StorytellerError.NotFound || e is StorytellerError.Forbidden) {
                        // Most likely about this item — the book was deleted
                        // server-side, or a permission was revoked for it — so
                        // the rest of the queue still deserves its turn. But
                        // only most likely: `ApiClient` maps a 404 or a 403 from
                        // *whatever* answered, and a reverse proxy whose
                        // Storyteller is down, or a path prefix that has
                        // changed, answers every route that way. Deleted on the
                        // spot, one drain emptied the whole offline backlog
                        // against it. Held until the drain is done.
                        refused.add(Refusal(item, e))
                    } else if (!e.isRetryable) {
                        // A refusal that will not change on retry and that no
                        // front door produces for every route — a payload the
                        // server would not take. Genuinely per-item, so the
                        // rest still goes.
                        //
                        // A discarded write is worth a line even when
                        // discarding is correct: this is where a rejected
                        // locator shape would go, and without it the position
                        // simply stops moving for no stated reason.
                        IssaLog.failure("sync mutation discarded", e, mapOf("kind" to item.kind.rawValue, "book" to item.bookUuid))
                        runCatching { queue.remove(item.id) }
                    } else {
                        failed(item, e)
                        reachedTheEnd = false
                        break
                    }
                } catch (e: Exception) {
                    failed(item, e)
                    reachedTheEnd = false
                    break
                }
            }
        }
        if (refused.isNotEmpty()) settle(refused, sent, askingTheServer = reachedTheEnd)
        return sent
    }

    /**
     * Anything else is worth another go later — but only a failure that could
     * implicate the write itself counts toward giving up on it. Every offline
     * drain used to count, and eight of them — well under a minute of reading
     * without signal, since each debounced save triggers one — quietly deleted
     * the head of the queue. A proxy's 502s were the same eight drains with a
     * status code on them; they do not count either.
     *
     * The caller stops on the first genuine failure: the connection is
     * probably gone, and hammering the rest achieves nothing.
     */
    private suspend fun failed(item: MutationQueue.Pending, error: Exception) {
        IssaLog.failure("sync mutation", error, mapOf("kind" to item.kind.rawValue))
        if (countsTowardAbandonment(error) && runCatching { queue.recordFailure(item.id) }.getOrDefault(false)) {
            // The one place a write is thrown away on this client's own
            // judgement, and until this line it said nothing.
            IssaLog.failure("sync mutation abandoned", error, mapOf("kind" to item.kind.rawValue, "book" to item.bookUuid))
        }
    }

    /**
     * Drops the rows this drain held as refused, once it knows Storyteller
     * refused them; otherwise keeps them for the next drain.
     *
     * The proof is Storyteller answering in this same drain: a row it took,
     * or — when every row was refused — one `GET /api/v2/user` that reads as a
     * user, which every version this client supports serves, 2.14.21
     * included. A front door answers that route as it answers the rest, with a
     * 404, a 403 or a page of its own, so its refusals stay queued and go
     * again once it lets Storyteller through. A refusal Storyteller made is
     * its verdict on the row, and the row goes as it always did — or a write
     * for a deleted book would be sent on every drain for ever.
     *
     * @param askingTheServer false when the drain stopped short — at a broken
     *   connection, which the question would only meet again, or with someone
     *   waiting for the lock, who should wait for no more requests than the
     *   one in flight.
     */
    private suspend fun settle(refused: List<Refusal>, sent: Int, askingTheServer: Boolean) {
        var storytellerAnswered = sent > 0
        if (!storytellerAnswered && askingTheServer && !queue.shouldYield) {
            storytellerAnswered = storytellerAnswers()
        }
        if (!storytellerAnswered) {
            IssaLog.warning(
                "sync refusals kept: nothing showed Storyteller made them",
                mapOf("count" to refused.size.toString(), "error" to refused[0].error.toString()),
            )
            return
        }
        for (refusal in refused) {
            IssaLog.failure(
                "sync mutation discarded", refusal.error,
                mapOf("kind" to refusal.item.kind.rawValue, "book" to refusal.item.bookUuid),
            )
            runCatching { queue.remove(refusal.item.id) }
        }
    }

    /**
     * Whether Storyteller itself is what answers this client's requests.
     *
     * A probe, not a request: it never throws and never touches the token,
     * because a 401 here — from a proxy or from Storyteller — says nothing the
     * refusals did not, and must not sign the reader out on the way.
     */
    private suspend fun storytellerAnswers(): Boolean {
        val probe = client.probeResponse(Endpoint.user) ?: return false
        if (probe.status !in 200..299) return false
        return runCatching { IssaJson.decodeFromString(User.serializer(), probe.data.decodeToString()) }.isSuccess
    }

    private suspend fun send(item: MutationQueue.Pending) {
        val text = item.payload.decodeToString()
        when (item.kind) {
            MutationQueue.Kind.POSITION -> {
                val payload = IssaJson.decodeFromString(PositionPayload.serializer(), text)
                client.post(Endpoint.positions(item.bookUuid), payload, PositionPayload.serializer())
            }
            MutationQueue.Kind.STATUS -> {
                val payload = IssaJson.decodeFromString(StatusPayload.serializer(), text)
                client.put(Endpoint.status(item.bookUuid), payload, StatusPayload.serializer())
            }
            MutationQueue.Kind.RATING -> {
                val payload = IssaJson.decodeFromString(RatingPayload.serializer(), text)
                val rating = payload.rating
                if (rating != null) {
                    client.put(
                        Endpoint.rating(item.bookUuid),
                        LibraryMutationService.Rating(rating = rating),
                        LibraryMutationService.Rating.serializer(),
                    )
                } else {
                    client.delete(Endpoint.rating(item.bookUuid))
                }
            }
        }
    }

    /**
     * Whether a failed attempt is evidence against the queued write itself.
     *
     * Abandonment exists for poisoned items: writes that will never send and,
     * because the drain stops at its first failure, block every write behind
     * them. A transport failure is not that — the request never reached the
     * server, and a queue that outlives an offline weekend is the whole point
     * of a durable one. A 429 is the server explicitly asking to be tried
     * later; obeying must not cost the write.
     *
     * Nor does a 502, 503 or 504. Those are what a reverse proxy says when the
     * Storyteller behind it is down — a container restarting — and they say
     * nothing about the payload. They are no rarer than eight drains, either:
     * every debounced save triggers one, and since the queue orders by
     * `updatedAt` a status or rating is the head of each of them, so a couple
     * of minutes of restart while reading used to delete it, for the next
     * refresh to put the old value back on screen.
     *
     * Any other 5xx *does* count — a judgement call: the server received
     * exactly this payload and choked, and a payload that reliably breaks a
     * route would otherwise sit at the head of the queue forever. Anything
     * unrecognised (a payload that no longer decodes, say) fails identically
     * every time, which is what poison means.
     */
    private fun countsTowardAbandonment(error: Exception): Boolean {
        if (error !is StorytellerError) return true
        return when (error) {
            is StorytellerError.Transport -> false
            is StorytellerError.Server -> error.status != 429 && error.status !in gatewayStatuses
            else -> true
        }
    }

    companion object {
        /**
         * Bad Gateway, Service Unavailable, Gateway Timeout: the answers of a
         * front door with nothing behind it. See [countsTowardAbandonment].
         */
        internal val gatewayStatuses: Set<Int> = setOf(502, 503, 504)
    }
}
