package com.benjaminissa.issareader.core.networking

import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI
import java.util.UUID

/**
 * Reading a server address: the first thing every reader types, and the
 * easiest thing to get wrong in a way that looks like the server is down.
 * Ported from `ServerAddressTests.swift`.
 */
class ServerAddressTest {
    // What one address means

    /** A bare host takes Storyteller's own default port. */
    @Test
    fun bareHostGetsDefaultPort() {
        assertEquals("http://storyteller.home.arpa:8001", ServerAddress.normalize("storyteller.home.arpa")!!.toString())
    }

    /** A full URL is taken at its word, port and all. */
    @Test
    fun fullUrlIsNotSecondGuessed() {
        assertEquals("https://books.example.com", ServerAddress.normalize("https://books.example.com")!!.toString())
        assertEquals("http://10.0.0.4:9999", ServerAddress.normalize("http://10.0.0.4:9999")!!.toString())
    }

    /** A subdirectory survives; a pasted API path and trailing slash do not. */
    @Test
    fun pathIsKeptButTidied() {
        assertEquals("https://example.com/books", ServerAddress.normalize("https://example.com/books/")!!.toString())
        assertEquals("https://example.com/books", ServerAddress.normalize("https://example.com/books/api/v2")!!.toString())
    }

    /** Nonsense is refused rather than guessed at. */
    @Test
    fun rejectsNonsense() {
        assertNull(ServerAddress.normalize(""))
        assertNull(ServerAddress.normalize("   "))
        assertNull(ServerAddress.normalize("http://"))
    }

    // What to try

    /**
     * A bare host tries HTTPS before Storyteller's raw port. A proxied server
     * answers on 443, and guessing 8001 connects to a port with nothing on it
     * — which hangs rather than refusing.
     */
    @Test
    fun bareHostTriesHttpsFirst() {
        val candidates = ServerAddress.candidates("storyteller.example.com")
        assertEquals(
            listOf("https://storyteller.example.com", "http://storyteller.example.com:8001"),
            candidates.map { it.toString() },
        )
    }

    /** An explicit scheme is the only thing tried: a deliberate http:// on a LAN must not be silently upgraded. */
    @Test
    fun explicitSchemeIsNotExpanded() {
        assertEquals(
            listOf("http://storyteller.home.arpa:8001"),
            ServerAddress.candidates("http://storyteller.home.arpa:8001").map { it.toString() },
        )
        assertEquals(listOf("https://books.example.com"), ServerAddress.candidates("https://books.example.com").map { it.toString() })
    }

    /** An address that means one thing is not tried twice. */
    @Test
    fun noDuplicates() {
        assertEquals(2, ServerAddress.candidates("example.com").size)
        assertEquals(2, ServerAddress.candidates("example.com").toSet().size)
    }

    /** Nothing typed is nothing to try. */
    @Test
    fun emptyIsEmpty() {
        assertTrue(ServerAddress.candidates("  ").isEmpty())
    }

    // What to remember

    /** A bare host that answered over HTTPS remembers the resolved URL. */
    @Test
    fun httpsAnswerIsStoredResolved() {
        val https = URI("https://books.example.com")
        assertFalse(ServerAddress.isCleartextFallback(https, forTyped = "books.example.com"))
        assertEquals("https://books.example.com", ServerAddress.addressToStore("books.example.com", connectedTo = https))
    }

    /** A cleartext fallback remembers what was typed, so HTTPS is retried. */
    @Test
    fun cleartextFallbackKeepsTypedText() {
        // A host of this run's own: the log store keeps six hours, so a fixed
        // phrase would be matched by the line any earlier run had written.
        val host = "library-${UUID.randomUUID().toString().lowercase()}.example.com"
        val http = URI("http://$host:8001")
        assertTrue(ServerAddress.isCleartextFallback(http, forTyped = host))
        assertEquals(host, ServerAddress.addressToStore(" $host ", connectedTo = http))
        // What is stored must re-derive the very URL that just answered, or
        // keeping raw text would break the session that stored it…
        assertEquals("http://$host:8001", ServerAddress.normalize(host)?.toString())
        // …and the next connect from it must still lead with HTTPS.
        assertEquals("https", ServerAddress.candidates(host).first().scheme)
        // The downgrade may only ever happen visibly: recording the address is
        // also what writes the warning a diagnostics export shows.
        val warned = IssaLog.export().split("\n").any { it.contains("cleartext HTTP") && it.contains(host) }
        assertTrue("the downgrade to $host left no warning in the log", warned)
    }

    /** A cleartext fallback does not remember a typed password. */
    @Test
    fun cleartextFallbackDropsUserinfo() {
        val host = "library-${UUID.randomUUID().toString().lowercase()}.example.com"
        val http = URI("http://$host:8001")
        for (typed in listOf("ben:hunter2@$host", "ben@$host?token=abc", "ben:hunter2@$host#top", "ben:hunter2@$host/shelf")) {
            val stored = ServerAddress.addressToStore(typed, connectedTo = http)
            assertFalse("$typed stored as $stored", stored.contains("ben"))
            assertTrue(!stored.contains("hunter2") && !stored.contains("token") && !stored.contains("top"))
            assertTrue(stored.startsWith(host))
            // Still a bare address, so the next connect leads with HTTPS…
            assertEquals("https", ServerAddress.candidates(stored).first().scheme)
        }
        // …and what is stored derives the URL that answered, path and all.
        val stored = ServerAddress.addressToStore("ben:hunter2@$host/shelf", connectedTo = http)
        assertEquals("$host/shelf", stored)
        assertEquals("http://$host:8001/shelf", ServerAddress.normalize(stored)?.toString())
    }

    /** An explicit http:// is not treated as a downgrade. */
    @Test
    fun explicitHttpIsNotADowngrade() {
        val url = URI("http://192.168.1.10:8001")
        assertFalse(ServerAddress.isCleartextFallback(url, forTyped = "http://192.168.1.10:8001"))
        assertEquals("http://192.168.1.10:8001", ServerAddress.addressToStore("http://192.168.1.10:8001", connectedTo = url))
    }
}

/**
 * Credentials in a typed address do not survive normalisation. Ported from
 * `ServerAddressUserinfoTests` in `ServerAddressTests.swift`.
 */
class ServerAddressUserinfoTest {
    /**
     * Userinfo is stripped the way the query and fragment already were. A
     * reader behind HTTP basic auth types the whole thing, and it used to
     * reach plaintext preferences, a keychain attribute and the Settings
     * screen.
     */
    @Test
    fun stripsUserinfo() {
        val url = ServerAddress.normalize("https://ben:hunter2@library.home.arpa")!!
        assertNull(url.userInfo)
        assertFalse(url.toString().contains("hunter2"))
        assertFalse(url.toString().contains("ben"))
        assertEquals("the server itself is still reachable", "library.home.arpa", url.host)
    }

    /** An address with no credentials is untouched. */
    @Test
    fun leavesOrdinaryAddressesAlone() {
        val url = ServerAddress.normalize("https://library.home.arpa/books")!!
        assertEquals("https://library.home.arpa/books", url.toString())
    }
}

/**
 * Whether the sign-in screen offers a stored sign-in at the same host's
 * plain-HTTP address: the condition `connect` asks before any probe. One
 * device that should be offered it, then one failing case per condition.
 */
class CleartextOfferTest {
    private val https = URI("https://storyteller.test")
    private val http = URI("http://storyteller.test:8001")

    /** A keychain of the test's own, by account. */
    private class Keychain(vararg held: Pair<String, String>) : TokenPersisting {
        val stored = HashMap(held.toMap())
        val reads = ArrayList<String>()

        override fun read(account: String): String? {
            reads.add(account)
            return stored[account]
        }

        override fun write(token: String, account: String): Boolean {
            stored[account] = token
            return true
        }

        override fun delete(account: String): Boolean {
            stored.remove(account)
            return true
        }
    }

    /** Probe answers by URL, null for no response at all; and every URL asked, in order. */
    private class Probe(private val answers: Map<URI, Int?>) {
        val asked = ArrayList<URI>()

        suspend fun status(url: URI): Int? {
            asked.add(url)
            return answers[url]
        }
    }

    private fun offer(
        address: String = "https://storyteller.test",
        stored: String = "https://storyteller.test",
        keychain: Keychain = Keychain(http.toString() to "token"),
        signedInAt: Set<URI> = emptySet(),
        probe: Probe = Probe(mapOf(https to null, http to 404)),
    ): ServerAddress.CleartextOffer? = runBlocking {
        ServerAddress.cleartextOffer(address, stored, keychain, { it in signedInAt }, probe::status)
    }

    /** The device the overwrite left behind: a dead stored https address, the sign-in under the http one, and http answering. */
    @Test
    fun theStrandedDeviceIsOfferedTheHttpSignIn() {
        val probe = Probe(mapOf(https to null, http to 404))
        assertEquals(ServerAddress.CleartextOffer(tried = https, offered = http), offer(probe = probe))
        assertEquals("the https address is asked first, then the http one", listOf(https, http), probe.asked)
    }

    /** G1: a freshly typed address is never offered a downgrade, and costs no keychain read or probe. */
    @Test
    fun aTypedAddressIsNotOffered() {
        val keychain = Keychain(http.toString() to "token")
        val probe = Probe(mapOf(https to null, http to 200))
        assertNull(
            runBlocking {
                ServerAddress.cleartextOffer("https://storyteller.test", "http://elsewhere.test:8001", keychain, { false }, probe::status)
            },
        )
        assertTrue(keychain.reads.isEmpty())
        assertTrue(probe.asked.isEmpty())
    }

    /** G2: a stored bare host has two candidates, and a stored http address is already plain. Neither is offered. */
    @Test
    fun onlyALoneHttpsAddressIsOffered() {
        val probe = Probe(mapOf(https to null, http to 200))
        assertNull(offer(address = "storyteller.test", stored = "storyteller.test", probe = probe))
        assertNull(offer(address = "http://storyteller.test:8001", stored = "http://storyteller.test:8001", probe = probe))
        assertTrue(probe.asked.isEmpty())
    }

    /** G3: a sign-in saved under the https address means that address is the one in use. */
    @Test
    fun aSignInUnderTheHttpsAddressEndsIt() {
        val probe = Probe(mapOf(https to null, http to 200))
        assertNull(offer(keychain = Keychain(https.toString() to "a", http.toString() to "b"), probe = probe))
        assertTrue(probe.asked.isEmpty())
    }

    /** G4: with no sign-in under the http address there is nothing to offer, and nothing is probed. */
    @Test
    fun noSignInUnderTheHttpAddressEndsIt() {
        val keychain = Keychain(URI("http://other.test:8001").toString() to "token")
        val probe = Probe(mapOf(https to null, http to 200))
        assertNull(offer(keychain = keychain, probe = probe))
        assertEquals(listOf(https.toString(), http.toString()), keychain.reads)
        assertTrue("a healthy device paid for a probe", probe.asked.isEmpty())
    }

    /**
     * A device that has ever been signed in at the https address is not the
     * stranded one: a reader who moved to https on an older build, left the
     * http token behind, and whose https session lapsed. No offer, no probe.
     */
    @Test
    fun aDeviceOnceSignedInOverHttpsIsNotOffered() {
        val probe = Probe(mapOf(https to null, http to 200))
        assertNull(offer(signedInAt = setOf(https), probe = probe))
        assertTrue("a device once signed in over https paid for a probe", probe.asked.isEmpty())
        // A record for another address is no such record.
        assertEquals(
            ServerAddress.CleartextOffer(tried = https, offered = http),
            offer(signedInAt = setOf(http, URI("https://elsewhere.test")), probe = Probe(mapOf(https to null, http to 200))),
        )
    }

    /** G5: any HTTP status at the https address, a 503 or a redirect included, means https is there: never downgraded. */
    @Test
    fun anHttpsAnswerOfAnyStatusEndsIt() {
        for (status in listOf(200, 302, 401, 404, 503)) {
            val probe = Probe(mapOf(https to status, http to 200))
            assertNull("https answered $status", offer(probe = probe))
            assertEquals("the http address was probed after https answered $status", listOf(https), probe.asked)
        }
    }

    /** G6: an http address that does not answer either is not worth offering. */
    @Test
    fun anHttpAddressThatDoesNotAnswerEndsIt() {
        assertNull(offer(probe = Probe(mapOf(https to null, http to null))))
        assertNull(offer(probe = Probe(mapOf(https to null, http to 502))))
    }

    /** The http twin keeps a port that was named, and adds Storyteller's only when none was. */
    @Test
    fun theTwinIsTheBareHostsHttpCandidate() {
        assertEquals(URI("http://storyteller.test:8001"), ServerAddress.cleartextTwin(URI("https://storyteller.test")))
        assertEquals(URI("http://storyteller.test:8443/books"), ServerAddress.cleartextTwin(URI("https://storyteller.test:8443/books")))
        assertNull(ServerAddress.cleartextTwin(URI("http://storyteller.test:8001")))
    }
}
