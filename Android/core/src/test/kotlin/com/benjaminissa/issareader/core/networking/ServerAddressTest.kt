package com.benjaminissa.issareader.core.networking

import com.benjaminissa.issareader.core.diagnostics.IssaLog
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
