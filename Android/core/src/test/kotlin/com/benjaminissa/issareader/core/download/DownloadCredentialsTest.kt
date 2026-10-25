package com.benjaminissa.issareader.core.download

import com.benjaminissa.issareader.core.networking.TokenProviding
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import java.net.URI

/**
 * The credentials a transfer is sent with as it runs. Android's backend keeps
 * its requests in WorkManager's database without them, so the manager is asked
 * each time: the token of the session it serves now, and only for its server.
 * No Swift counterpart: URLSession keeps its requests in the app's own keeping.
 */
class DownloadCredentialsTest {
    private class Tokens(private val token: String?) : TokenProviding {
        override suspend fun currentToken(): String? = token
        override suspend fun invalidate() {}
    }

    @Test
    fun theServersOwnFilesGetTheCurrentToken() = runTest {
        val manager = downloadManager(tokens = Tokens("first"))
        val file = URI("$unreachableServer/api/v2/books/uuid/files?format=ebook")
        assertEquals(mapOf("Authorization" to "Bearer first"), manager.credentials(file))

        // A sign-in since the transfer was queued: its token, not the old one.
        manager.reconfigure(unreachableServer, Tokens("second"))
        assertEquals(mapOf("Authorization" to "Bearer second"), manager.credentials(file))

        // The default port written out is the same server.
        assertEquals(mapOf("Authorization" to "Bearer second"), manager.credentials(URI("http://192.0.2.1:80/api/v2/books")))
    }

    @Test
    fun anotherOriginGetsNothing() = runTest {
        val manager = downloadManager(tokens = Tokens("secret"))
        for (elsewhere in listOf(
            "http://192.0.2.2/api/v2/books",
            "https://192.0.2.1/api/v2/books",
            "http://192.0.2.1:8001/api/v2/books",
            "http://cdn.example.com/book.epub",
        )) {
            assertEquals(elsewhere, emptyMap<String, String>(), manager.credentials(URI(elsewhere)))
        }
    }

    @Test
    fun signedOutGetsNothing() = runTest {
        val manager = downloadManager(tokens = Tokens(null))
        assertEquals(emptyMap<String, String>(), manager.credentials(URI("$unreachableServer/api/v2/books")))
    }
}
