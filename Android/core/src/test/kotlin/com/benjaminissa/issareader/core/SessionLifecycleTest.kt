package com.benjaminissa.issareader.core

import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.core.auth.TokenStore
import com.benjaminissa.issareader.core.networking.Endpoint
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ConnectException
import java.net.URI
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource

/**
 * Answers a [Session]'s requests the way one kind of server does, chosen by
 * the request's **host**, and records every request it sees — so tests never
 * answer one another's, and a test can ask whether a route was called at all.
 */
private object LifecycleStub {
    /** Signs in, then sits on the logout POST for longer than any test waits. */
    const val SLOW_LOGOUT = "slow-logout.lifecycle.test"

    /**
     * Unreachable for the identity call; reachable, and refusing the token,
     * for everything else — the server coming back after a cold launch
     * offline, with the token revoked in the meantime.
     */
    const val UNREACHABLE_IDENTITY = "unreachable-identity.lifecycle.test"

    /** Signs in, then refuses the token on the library route. */
    const val REVOKES = "revokes.lifecycle.test"

    /**
     * Signs in, and answers the logout POST after [PROMPT_ANSWER_MILLIS] —
     * well inside any test's timeout, but late enough that a sign-out which
     * did not wait for it returns before the answer exists.
     */
    const val PROMPT_LOGOUT = "prompt-logout.lifecycle.test"
    const val PROMPT_ANSWER_MILLIS = 300L

    /**
     * How long the slow logout takes to answer: far past the test's own
     * bound, short enough that an unbounded sign-out fails rather than hangs.
     */
    const val SLOW_ANSWER_MILLIS = 10_000L

    private val seen: MutableList<String> = Collections.synchronizedList(mutableListOf())

    /** The same requests, each with the `Authorization` it carried. */
    private val authorised: MutableList<String> = Collections.synchronizedList(mutableListOf())

    /** Requests whose answer has been delivered, as "host METHOD path". */
    private val answered: MutableList<String> = Collections.synchronizedList(mutableListOf())

    /** The requests to [host] that have had their answer. */
    fun answers(host: String): List<String> = synchronized(answered) { answered.filter { it.startsWith("$host ") } }

    fun requests(host: String): List<String> = synchronized(seen) { seen.filter { it.startsWith("$host ") } }

    /** "METHOD path | Authorization" for every request to [host]. */
    fun authorisations(host: String): List<String> =
        synchronized(authorised) { authorised.filter { it.startsWith("$host ") }.map { it.drop(host.length + 1) } }

    val http = stubHttp { request ->
        val host = request.url.host
        val path = request.url.encodedPath
        val method = request.method
        seen.add("$host $method $path")
        authorised.add("$host $method $path | ${request.header("Authorization") ?: "none"}")

        fun answer(status: Int, body: String): Stub {
            answered.add("$host $method $path")
            return Stub.Answer(status, body, mapOf("Content-Type" to "application/json"))
        }

        when {
            host == UNREACHABLE_IDENTITY && path == Endpoint.user -> Stub.Fail(ConnectException("Connection refused"))
            host == UNREACHABLE_IDENTITY || (host == REVOKES && path == Endpoint.books) -> answer(401, "")
            path == Endpoint.user -> answer(200, fixture("user"))
            (host == SLOW_LOGOUT || host == PROMPT_LOGOUT) && path == Endpoint.logout -> {
                Thread.sleep(if (host == PROMPT_LOGOUT) PROMPT_ANSWER_MILLIS else SLOW_ANSWER_MILLIS)
                answer(200, "{}")
            }
            else -> answer(200, "{}")
        }
    }
}

/**
 * Token storage that can be told to refuse, the way device storage refuses a
 * write before first unlock or a delete it cannot complete.
 */
private class MemoryTokens(
    holding: Map<String, String> = emptyMap(),
    private val refusesWrites: Boolean = false,
    private val refusesDeletes: Boolean = false,
) : TokenPersisting {
    private val stored = ConcurrentHashMap(holding)

    fun token(account: String): String? = stored[account]

    override fun read(account: String): String? = token(account)

    override fun write(token: String, account: String): Boolean {
        if (refusesWrites) return false
        stored[account] = token
        return true
    }

    override fun delete(account: String): Boolean {
        if (refusesDeletes) return false
        stored.remove(account)
        return true
    }
}

/**
 * A session's lifecycle: signing out, expiring, saving the token. Ported from
 * `SessionLifecycleTests.swift`.
 */
class SessionLifecycleTest {
    private fun server(host: String): URI = URI("http://$host")

    private fun session(host: String, keychain: MemoryTokens, logoutTimeout: Duration = 5.seconds): Session =
        Session(serverUrl = server(host), keychain = keychain, http = LifecycleStub.http, logoutTimeout = logoutTimeout)

    /**
     * Polls a condition for a bounded time — the invalidation lands a turn
     * after the 401 that caused it.
     */
    private suspend fun eventually(within: Duration = 2.seconds, condition: () -> Boolean): Boolean {
        val deadline = TimeSource.Monotonic.markNow() + within
        while (deadline.hasNotPassedNow()) {
            if (condition()) return true
            delay(10)
        }
        return condition()
    }

    // F06#3 — a sign-out the network cannot hold up

    /** Signing out with a server that never answers the logout returns promptly, signed out, token gone. */
    @Test
    fun signOutIsBounded() = runBlocking {
        val host = LifecycleStub.SLOW_LOGOUT
        val keychain = MemoryTokens()
        // A second, not less: the limit must leave the POST time to reach the
        // server on a loaded machine. What the test proves is that sign-out is
        // bounded, not the transport's own timeout.
        val session = session(host, keychain, logoutTimeout = 1.seconds)
        session.adopt("minted")
        assertTrue("did not sign in: ${session.state.value}", session.state.value is Session.State.SignedIn)

        val started = TimeSource.Monotonic.markNow()
        session.signOut()
        val elapsed = started.elapsedNow()

        assertTrue("sign-out waited $elapsed on the logout", elapsed < 5.seconds)
        assertEquals(Session.State.SignedOut, session.state.value)
        assertNull(keychain.token(server(host).toString()))
        assertFalse(session.hasStoredCredential())
        // The revoke is not cancelled by the deadline, so on a loaded machine
        // it may reach the server after sign-out has returned.
        assertTrue(
            "the revoke was still attempted",
            eventually(5.seconds) { LifecycleStub.requests(host).contains("$host POST ${Endpoint.logout}") },
        )
    }

    /**
     * A revoke that starts after the deadline is still sent, with the token
     * it revokes — which the store no longer holds by then.
     */
    @Test
    fun lateRevokeIsSentAuthorised() = runBlocking {
        val host = "held-logout.lifecycle.test"
        val keychain = MemoryTokens()
        val session = session(host, keychain, logoutTimeout = 100.milliseconds)
        session.adopt("minted")
        assertTrue("did not sign in: ${session.state.value}", session.state.value is Session.State.SignedIn)
        val gate = CompletableDeferred<Unit>()
        session.logoutWillSend = { gate.await() }

        val started = TimeSource.Monotonic.markNow()
        session.signOut()
        val elapsed = started.elapsedNow()

        assertTrue("sign-out waited $elapsed on the held revoke", elapsed < 5.seconds)
        assertEquals(Session.State.SignedOut, session.state.value)
        assertFalse(session.hasStoredCredential())
        assertFalse("held: nothing sent yet", LifecycleStub.requests(host).contains("$host POST ${Endpoint.logout}"))

        gate.complete(Unit)

        val revoke = "POST ${Endpoint.logout} | Bearer minted"
        assertTrue(
            "sent: ${LifecycleStub.authorisations(host)}",
            eventually(5.seconds) { LifecycleStub.authorisations(host).contains(revoke) },
        )
    }

    /**
     * R-67. Sign-out waits, within its bound, for a logout the server answers
     * in time, and sends it with the token.
     */
    @Test
    fun signOutWaitsForAPromptLogout() = runBlocking {
        val host = LifecycleStub.PROMPT_LOGOUT
        val keychain = MemoryTokens()
        val session = session(host, keychain)
        session.adopt("minted")
        session.signOut()
        assertEquals(Session.State.SignedOut, session.state.value)
        assertNull(keychain.token(server(host).toString()))
        // Checked the moment sign-out returns, not eventually: the answer had
        // to be in before it did.
        assertTrue(
            "sign-out returned before the logout was answered: ${LifecycleStub.answers(host)}",
            LifecycleStub.answers(host).contains("$host POST ${Endpoint.logout}"),
        )
        assertTrue(LifecycleStub.authorisations(host).contains("POST ${Endpoint.logout} | Bearer minted"))
    }

    // F06#4 — a token that dies while the session sits in `Failed`

    /** A 401 after an offline restore left the session failed moves it to expired. */
    @Test
    fun failedSessionExpires() = runBlocking {
        val host = LifecycleStub.UNREACHABLE_IDENTITY
        val key = server(host).toString()
        val keychain = MemoryTokens(holding = mapOf(key to "stored"))
        val session = session(host, keychain)

        session.restore()
        assertTrue("restore did not fail at transport: ${session.state.value}", session.state.value is Session.State.Failed)

        // The server is back, and refuses the token.
        runCatching { session.client.getData(Endpoint.books) }

        assertTrue("state stayed ${session.state.value}", eventually { session.state.value == Session.State.Expired })
        assertNull(keychain.token(key))
        assertFalse(session.hasStoredCredential())
    }

    /** A 401 while signed in still moves the session to expired. */
    @Test
    fun signedInSessionExpires() = runBlocking {
        val host = LifecycleStub.REVOKES
        val session = session(host, MemoryTokens())
        session.adopt("minted")
        assertTrue("did not sign in: ${session.state.value}", session.state.value is Session.State.SignedIn)
        runCatching { session.client.getData(Endpoint.books) }
        assertTrue("state stayed ${session.state.value}", eventually { session.state.value == Session.State.Expired })
    }

    // F06#5 — storage that refuses the token

    /** A token the device refuses to store fails the sign-in without asking who it belongs to. */
    @Test
    fun refusedWriteFailsSignIn() = runBlocking {
        val host = "refused-write.lifecycle.test"
        val session = session(host, MemoryTokens(refusesWrites = true))

        session.adopt("minted")

        assertEquals(Session.State.Failed("Your sign-in couldn't be saved on this device. Try again."), session.state.value)
        assertTrue("requests sent: ${LifecycleStub.requests(host)}", LifecycleStub.requests(host).isEmpty())
        assertFalse("an unsaved token is not held either", session.hasStoredCredential())
    }

    /** The token store reports what storage did with a write and a delete. */
    @Test
    fun tokenStoreReportsStorage() = runBlocking {
        val refusing = TokenStore(
            serverKey = "k",
            keychain = MemoryTokens(holding = mapOf("k" to "old"), refusesWrites = true, refusesDeletes = true),
        )
        assertEquals(false, refusing.set("new"))
        assertEquals("memory still mirrors storage", "old", refusing.currentToken())
        assertEquals(false, refusing.forget())

        val keychain = MemoryTokens()
        val accepting = TokenStore(serverKey = "k", keychain = keychain)
        assertTrue(accepting.set("new"))
        assertEquals("new", keychain.token("k"))
        assertTrue(accepting.forget())
        assertNull(keychain.token("k"))
        assertFalse(accepting.hasToken())
    }

    /**
     * A delete the device refuses still signs the session out: the reader
     * asked to be signed out, and is.
     */
    @Test
    fun refusedDeleteStillSignsOut() = runBlocking {
        // Its own host, so its logout can never answer another test's check.
        val host = "refused-delete.lifecycle.test"
        val session = session(host, MemoryTokens(refusesDeletes = true))
        session.adopt("minted")
        session.signOut()
        assertEquals(Session.State.SignedOut, session.state.value)
        assertFalse(session.hasStoredCredential())
    }
}
