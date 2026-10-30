package com.benjaminissa.issareader.core

import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ServerGeneration
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.ProbeResponse
import com.benjaminissa.issareader.core.networking.TokenProviding
import com.benjaminissa.issareader.core.sync.LibraryService
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI

/**
 * One set of captured responses per Storyteller the client is tested
 * against: the two release pins and the older tags it must still work with.
 * Each was captured from a running server, with the LAN address rewritten to
 * `storyteller.test`.
 *
 * New captures go beside the old ones, never in their place (CLAUDE.md,
 * "Older servers"): every unit run keeps decoding what 2.14.21 and beta.40
 * send next to what the pins send.
 */
enum class CapturedServer(val rawValue: String) {
    /** `Fixtures/` — trimmed to five books by hand. */
    V2_14_21("web-v2.14.21"),

    /** `Fixtures/v2-14-23/` — the whole library. */
    V2_14_23("web-v2.14.23"),

    /** `Fixtures/v3/` — the whole library, migrated from the 2.14.21 data. */
    V3_BETA40("web-v3.0.0-beta.40"),

    /** `Fixtures/v3/beta46/` — the same library after the server moved on. */
    V3_BETA46("web-v3.0.0-beta.46"),

    /** `Fixtures/v3/beta49/` — the library once more, a pin later. */
    V3_BETA49("web-v3.0.0-beta.49"),

    /**
     * `Fixtures/v3/beta56/` — and on the current pin, which added
     * `progress-sync/v3` to the capabilities and nothing the client reads.
     */
    V3_BETA56("web-v3.0.0-beta.56"),
    ;

    /** The capture's name under `Fixtures/`, without `.json`. */
    fun fixture(name: String): String = when (this) {
        V2_14_21 -> name
        V2_14_23 -> "v2-14-23/$name"
        V3_BETA40 -> "v3/$name"
        V3_BETA46 -> "v3/beta46/$name"
        V3_BETA49 -> "v3/beta49/$name"
        V3_BETA56 -> "v3/beta56/$name"
    }

    val isV3: Boolean get() = this == V3_BETA40 || this == V3_BETA46 || this == V3_BETA49 || this == V3_BETA56

    fun books(): List<Book> = fixtureBooks(fixture("books"))

    fun statuses(): List<Status> = fixtureStatuses(fixture("statuses"))

    override fun toString(): String = rawValue
}

/** Every tested server's captures decode. Ported from `CapturedGenerationsTests.swift`. */
class CapturedGenerationsTest {
    /**
     * The whole books capture decodes, and no book is refused. On the whole
     * array: one book that fails to decode throws the entire catalogue away.
     */
    @Test
    fun booksDecode() {
        for (server in CapturedServer.entries) {
            val books = server.books()
            assertFalse("$server", books.isEmpty())
            assertEquals("$server", books.size, LibraryService.refusingUnsafeIdentifiers(books).size)
            assertTrue("$server", books.all { it.uuid.isNotEmpty() && it.title.isNotEmpty() })
            assertTrue("every captured book has a file on $server", books.all { it.availableFormats.isNotEmpty() })
        }
    }

    /** The statuses capture decodes, with the three built-in names. */
    @Test
    fun statusesDecode() {
        for (server in CapturedServer.entries) {
            val names = server.statuses().map { it.name }.toSet()
            assertTrue("$server", names.containsAll(setOf("To read", "Reading", Status.readName)))
        }
    }

    /** 3.x shapes decode on every beta: no status, a relabelled status, a custom one. Only 3.x lets a book have no status, or an admin relabel one. */
    @Test
    fun v3Shapes() {
        for (server in listOf(CapturedServer.V3_BETA40, CapturedServer.V3_BETA46, CapturedServer.V3_BETA49, CapturedServer.V3_BETA56)) {
            val books = server.books()
            fun book(title: String): Book = books.firstOrNull { it.title == title } ?: error("no $title in the $server capture")
            assertNull(book("Emma").status)
            assertNull(book("The Time Machine").status)
            val peter = book("Peter and Wendy").status!!
            assertEquals(Status.readName, peter.name)
            assertEquals("Finished", peter.displayName)
            assertEquals("Abandoned", book("Moby Dick; Or, The Whale").status?.displayName)
            // Every ebook has art except the two Gap Books, made for the
            // read-along checks with none: a coverless ebook decodes with no
            // cover reference rather than failing the catalogue.
            for (each in books) {
                if (each.title.startsWith("The Gap Book")) {
                    assertTrue("${each.title} has no art", each.ebook != null && each.ebook?.cover == null)
                } else {
                    assertTrue("${each.title}'s ebook cover on $server", each.ebook?.cover?.isUsable == true)
                }
            }
        }
    }

    /**
     * beta.46 shows every book it shares with beta.40 the same way. The
     * upgrade from beta.40 to beta.46 migrated the library in place, so every
     * book the two captures share must read the same in the app: the same
     * title, the same status label, the same cover references.
     */
    @Test
    fun beta46MatchesBeta40() {
        val older = CapturedServer.V3_BETA40.books()
        val newer = CapturedServer.V3_BETA46.books().associateBy { it.uuid }
        assertEquals(25, older.size)
        for (book in older) {
            val moved = newer[book.uuid]
            assertNotNull("${book.title} is missing from the beta.46 capture", moved)
            moved!!
            assertEquals(book.title, moved.title)
            assertEquals("${book.title}'s status", book.status?.displayName, moved.status?.displayName)
            assertEquals("${book.title}'s ebook cover", book.ebook?.cover, moved.ebook?.cover)
            assertEquals("${book.title}'s audiobook cover", book.audiobook?.cover, moved.audiobook?.cover)
            assertEquals("${book.title}'s read-along cover", book.readaloud?.cover, moved.readaloud?.cover)
        }
    }

    /** beta.49 shows every book it shares with beta.46 the same way, on the data beta.46 had migrated. */
    @Test
    fun beta49MatchesBeta46() {
        val older = CapturedServer.V3_BETA46.books()
        val newer = CapturedServer.V3_BETA49.books().associateBy { it.uuid }
        assertEquals(27, older.size)
        for (book in older) {
            val moved = newer[book.uuid]
            assertNotNull("${book.title} is missing from the beta.49 capture", moved)
            moved!!
            assertEquals(book.title, moved.title)
            assertEquals("${book.title}'s status", book.status?.displayName, moved.status?.displayName)
            assertEquals("${book.title}'s ebook cover", book.ebook?.cover, moved.ebook?.cover)
            assertEquals("${book.title}'s audiobook cover", book.audiobook?.cover, moved.audiobook?.cover)
            assertEquals("${book.title}'s read-along cover", book.readaloud?.cover, moved.readaloud?.cover)
        }
    }

    /** And from beta.49 to beta.56, whose migration only added tables. */
    @Test
    fun beta56MatchesBeta49() {
        val older = CapturedServer.V3_BETA49.books()
        val newer = CapturedServer.V3_BETA56.books().associateBy { it.uuid }
        assertEquals(27, older.size)
        for (book in older) {
            val moved = newer[book.uuid]
            assertNotNull("${book.title} is missing from the beta.56 capture", moved)
            moved!!
            assertEquals(book.title, moved.title)
            assertEquals("${book.title}'s status", book.status?.displayName, moved.status?.displayName)
            assertEquals("${book.title}'s ebook cover", book.ebook?.cover, moved.ebook?.cover)
            assertEquals("${book.title}'s audiobook cover", book.audiobook?.cover, moved.audiobook?.cover)
            assertEquals("${book.title}'s read-along cover", book.readaloud?.cover, moved.readaloud?.cover)
        }
    }

    /** 2.x books always carry a built-in status: 2.x has no relabelling and no empty status. */
    @Test
    fun v2Statuses() {
        val builtIn = setOf("To read", "Reading", Status.readName)
        for (server in listOf(CapturedServer.V2_14_21, CapturedServer.V2_14_23)) {
            for (book in server.books()) {
                val status = book.status
                assertNotNull("${book.title} has no status on $server", status)
                assertTrue(status!!.name in builtIn)
            }
        }
    }

    /** A 3.x beta's identity says 3.x, and its details report that beta. */
    @Test
    fun betaIdentity() = runBlocking {
        for (server in listOf(CapturedServer.V3_BETA46, CapturedServer.V3_BETA49, CapturedServer.V3_BETA56)) {
            val identity = fixture(server.fixture("server-public")).encodeToByteArray()
            assertEquals(ServerGeneration.V3, Session.generation(ProbeResponse(200, identity)))

            val client = ApiClient(baseUrl = URI("http://${hosts.getValue(server)}"), tokens = BetaTokens(), http = capturedBetaStub)
            val caps = Session.probeCapabilities(client)
            val version = server.rawValue.removePrefix("web-v")
            assertEquals(ServerGeneration.V3, caps.generation)
            assertEquals(version, caps.reportedVersion)
            assertEquals(version, caps.displayVersion)
        }
    }

    companion object {
        /** What the stub below answers for, by the host the client is pointed at. */
        val hosts = mapOf(
            CapturedServer.V3_BETA46 to "beta46.storyteller.test",
            CapturedServer.V3_BETA49 to "beta49.storyteller.test",
            CapturedServer.V3_BETA56 to "beta56.storyteller.test",
        )

        /**
         * A beta as `Session.probeCapabilities` sees it: the captured identity
         * and details of whichever one the host names, every other route a 404.
         */
        private val capturedBetaStub = stubHttp { request ->
            val name = when (request.url.encodedPath) {
                Endpoint.V3.serverPublic -> "server-public"
                Endpoint.V3.serverDetails -> "server-details"
                else -> null
            }
            val server = hosts.entries.firstOrNull { it.value == request.url.host }?.key
            val body = if (name != null && server != null) fixture(server.fixture(name)) else null
            Stub.Answer(if (body == null) 404 else 200, body ?: "", mapOf("Content-Type" to "application/json"))
        }
    }
}

private class BetaTokens : TokenProviding {
    override suspend fun currentToken(): String = "probe-token"
    override suspend fun invalidate() {}
}

