package com.benjaminissa.issareader.core.diagnostics

import com.benjaminissa.issareader.core.networking.StorytellerError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.UnknownHostException
import java.time.Instant
import java.util.UUID

/**
 * The log exists to be handed to somebody else, which is what makes both of
 * these rules load-bearing: it must carry the last six hours, and it must
 * never carry a credential. Ported from `IssaLogTests.swift`.
 */
class IssaLogTest {
    /**
     * Each file-backed test gets its own directory. The store is a singleton
     * in the app and a shared file on disk, so tests running in parallel
     * otherwise read each other's lines.
     */
    private fun temporaryStore(): LogStore =
        LogStore(root = File(System.getProperty("java.io.tmpdir"), "issalog-${UUID.randomUUID()}"))

    /**
     * Goes through the same builder the app writes with. Rebuilding it here
     * would make every redaction test pass with the redaction deleted.
     */
    private fun entry(
        message: String,
        fields: Map<String, String> = emptyMap(),
        agoSeconds: Long = 0,
        level: IssaLog.Level = IssaLog.Level.INFO,
    ): IssaLog.Entry = IssaLog.entry(level, message, fields, at = Instant.now().minusSeconds(agoSeconds))

    private fun sixHoursAgo(): Instant = Instant.now().minus(IssaLog.window)

    // Redaction

    /** A bearer token never reaches the file. */
    @Test
    fun redactsBearerToken() {
        val line = entry("GET /books failed: Authorization: Bearer eyJhbGciOiJIUzI1.abc-DEF_123").line
        assertFalse(line.contains("eyJhbGciOiJIUzI1"))
        assertTrue(line.contains("«redacted»"))
    }

    /** A field named as a secret loses its value whatever it looks like. */
    @Test
    fun redactsSecretFields() {
        val line = entry("signing in", mapOf("device_code" to "plainlookingvalue", "server" to "s.example")).line
        assertFalse(line.contains("plainlookingvalue"))
        assertTrue("the useful fields must survive", line.contains("server=s.example"))
    }

    /** The short code shown on screen is not recorded. */
    @Test
    fun redactsUserCode() {
        assertFalse(entry("approve CCXV-LZTD to continue").line.contains("CCXV-LZTD"))
    }

    /**
     * A UUID survives the code pattern. Over-redaction is its own failure. A
     * log that has had the identifiers scrubbed out of it cannot be matched
     * against anything, and the code pattern is a shape UUIDs contain.
     */
    @Test
    fun keepsUuids() {
        val uuid = "79073E71-3E86-4B2C-A649-E4AB99371125"
        assertTrue(entry("task $uuid failed").line.contains(uuid))
    }

    /**
     * A secret inside a JSON body is not recorded. The rule promised
     * `"key": "value"` and caught only `key=value` and `key: value`: in JSON
     * the key is quoted, and the quote between the key and the colon let every
     * secret in a body through untouched.
     */
    @Test
    fun redactsJsonQuotedSecrets() {
        val compact = entry("""refresh answered {"token":"abcDEF123","expires":3600}""").line
        assertFalse(compact.contains("abcDEF123"))
        assertTrue("the rest of the body survives", compact.contains("3600"))

        val spaced = entry("""sign-in answered { "access_token" : "xyz789QRS", "token_type": "bearer" }""").line
        assertFalse(spaced.contains("xyz789QRS"))

        val field = entry("refresh failed", mapOf("body" to """{"refresh_token": "rft456LMN"}""")).line
        assertFalse("a field not named as a secret is scrubbed the same way", field.contains("rft456LMN"))
    }

    /** A token embedded in a URL query is not recorded. */
    @Test
    fun redactsQueryToken() {
        val line = entry("polling https://s.example/token?device_code=UBHO1MuQZWx81snQ").line
        assertFalse(line.contains("UBHO1MuQZWx81snQ"))
    }

    /**
     * Credentials typed into the server address are not recorded. A reverse
     * proxy with basic auth means the password is *in* the server address, and
     * the address is logged everywhere a request can fail.
     */
    @Test
    fun redactsUrlCredentials() {
        val line = entry("library refresh failed", mapOf("server" to "https://ben:hunter2@books.example.com")).line
        assertFalse(line.contains("hunter2"))
        assertFalse(line.contains("ben:"))
        assertTrue("the host is what makes the report legible", line.contains("books.example.com"))
    }

    /**
     * Credentials in a URL inside an error description are not recorded. The
     * same URL rides inside transport error descriptions, which no call-site
     * rule could catch — the scrub has to work on prose.
     */
    @Test
    fun redactsUrlCredentialsInProse() {
        val line = entry(
            "Error Domain=NSURLErrorDomain Code=-1004 " +
                "NSErrorFailingURLKey=https://ben:hunter2@books.example.com/api/v2/books",
        ).line
        assertFalse(line.contains("hunter2"))
        assertTrue(line.contains("books.example.com/api/v2/books"))
    }

    /** An address without credentials is kept whole: a plain URL must survive the userinfo rule untouched. */
    @Test
    fun keepsPlainUrls() {
        val line = entry("connected", mapOf("server" to "https://books.example.com/api")).line
        assertTrue(line.contains("https://books.example.com/api"))
    }

    /**
     * What makes a report legible is kept. The other half of the bargain. A
     * log that redacts the server address and the book title is safe and
     * useless.
     */
    @Test
    fun keepsUsefulContext() {
        val line = entry(
            "download failed",
            mapOf("book" to "Peter and Wendy", "server" to "storyteller.example.com", "status" to "503"),
        ).line
        assertTrue(line.contains("Peter and Wendy"))
        assertTrue(line.contains("storyteller.example.com"))
        assertTrue(line.contains("503"))
    }

    /** A secret key is recognised however it is spelled. */
    @Test
    fun recognisesSecretKeys() {
        for (key in listOf("Authorization", "ACCESS_TOKEN", "user-code", "Password")) {
            assertTrue(key, IssaLog.Redaction.isSecret(key))
        }
    }

    /** An ordinary key is not mistaken for a secret. */
    @Test
    fun leavesOrdinaryKeys() {
        for (key in listOf("server", "book", "status", "site", "chapter")) {
            assertFalse(key, IssaLog.Redaction.isSecret(key))
        }
    }

    // The six-hour window

    /** An entry older than six hours is not exported. */
    @Test
    fun dropsOldEntries() {
        val store = temporaryStore()
        try {
            store.append(entry("seven hours ago", agoSeconds = 7 * 3600))
            store.append(entry("one hour ago", agoSeconds = 3600))
            val text = store.text(sixHoursAgo())
            assertTrue(text.contains("one hour ago"))
            assertFalse(text.contains("seven hours ago"))
        } finally {
            store.clear()
        }
    }

    /** Entries come back oldest first, so a report reads forwards. */
    @Test
    fun ordersOldestFirst() {
        val store = temporaryStore()
        try {
            store.append(entry("later", agoSeconds = 60))
            store.append(entry("earlier", agoSeconds = 3600))
            val lines = store.entries(sixHoursAgo()).map { it.message }
            assertEquals(listOf("earlier", "later"), lines)
        } finally {
            store.clear()
        }
    }

    /**
     * Entries milliseconds apart keep their order through the file.
     *
     * The file used to be written with whole-second stamps, so two entries
     * milliseconds apart came back simultaneous, and could come back
     * reordered, in the report that exists to say which happened first.
     */
    @Test
    fun keepsMillisecondOrder() {
        val store = temporaryStore()
        try {
            val base = Instant.now().minusSeconds(60)
            store.append(IssaLog.entry(IssaLog.Level.INFO, "position moved", emptyMap(), at = base))
            store.append(IssaLog.entry(IssaLog.Level.ERROR, "sync mutation failed", emptyMap(), at = base.plusMillis(4)))
            val entries = store.entries(sixHoursAgo())
            assertEquals(listOf("position moved", "sync mutation failed"), entries.map { it.message })
            // Not merely ordered: the times themselves must survive distinct,
            // or the sort above is deciding by luck.
            assertTrue(entries.size == 2 && entries[0].time.isBefore(entries[1].time))
        } finally {
            store.clear()
        }
    }

    /**
     * A second reader of the same files sees what the first wrote. The log
     * survives a relaunch — the whole reason it is a file and not the
     * platform's per-process log.
     */
    @Test
    fun survivesANewStore() {
        val directory = File(System.getProperty("java.io.tmpdir"), "issalog-${UUID.randomUUID()}")
        val first = LogStore(root = directory)
        try {
            first.append(entry("written before the crash"))
            first.flush()
            val second = LogStore(root = directory)
            assertTrue(second.text(sixHoursAgo()).contains("written before the crash"))
        } finally {
            first.clear()
        }
    }

    /** An empty log says so rather than exporting nothing. */
    @Test
    fun emptyLogIsExplained() {
        val store = temporaryStore()
        try {
            assertTrue(store.text(sixHoursAgo()).contains("No activity"))
        } finally {
            store.clear()
        }
    }

    // What an error is worth keeping

    /** An HTTP failure records its status. */
    @Test
    fun describesServerError() {
        val fields = IssaLog.describe(StorytellerError.Server(status = 503, serverMessage = "down"))
        assertEquals("503", fields["status"])
        assertEquals("down", fields["serverMessage"])
        assertEquals("true", fields["retryable"])
    }

    /**
     * A transport exception keeps what identifies it.
     *
     * Swift records an `NSError`'s domain and code (`NSURLErrorDomain`,
     * -1009); a JVM failure is identified by its class, which is what `domain`
     * carries here, and it has no numeric code to go with it.
     */
    @Test
    fun describesTransportError() {
        val fields = IssaLog.describe(UnknownHostException("storyteller.test"))
        assertEquals("java.net.UnknownHostException", fields["domain"])
        assertTrue(fields["error"]!!.contains("storyteller.test"))
    }
}
