package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.core.networking.ApiClient
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI

/** The probe that picks which of the addresses someone typed has a Storyteller behind it. */
class ServerProbeTest {
    /**
     * The probe goes through the app's own client, so the connection that
     * answered is still open for the sign-in that follows it. A client of the
     * probe's own started threads for the one request and closed that
     * connection as it finished.
     */
    @Test
    fun `the probe finds the address that answers, and keeps its connection for the sign-in`() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().code(200).body("{}").build())
            server.start()
            val pool = ApiClient.sharedHttpClient.connectionPool
            pool.evictAll()
            // Nothing listens on port 1: refused at once.
            val nothing = URI("http://127.0.0.1:1")
            val storyteller = URI(server.url("/").toString())

            assertEquals(storyteller, AppModel.firstReachable(listOf(nothing, storyteller), timeoutSeconds = 2))
            assertEquals("/api/v2/server/public", server.takeRequest().url.encodedPath)
            assertTrue("the connection that answered was closed", pool.idleConnectionCount() >= 1)
        }
    }
}
