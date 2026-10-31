package com.benjaminissa.issareader.core.networking

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The shared transport waits as long as the iPhone's does.
 *
 * Downloads, API calls and streamed audio all go through it. With OkHttp's own
 * 10-second default, a server — or the proxy in front of it — that took longer
 * than that to start sending a large read-along failed every download on
 * Android with "timeout", where the iPhone's URLSession, waiting 60, finished.
 */
class SharedHttpClientTest {
    private val client = ApiClient.sharedHttpClient

    @Test
    fun `it waits a minute without a byte, as URLSession does`() {
        assertEquals(60_000, client.connectTimeoutMillis)
        assertEquals(60_000, client.readTimeoutMillis)
        assertEquals(60_000, client.writeTimeoutMillis)
    }

    @Test
    fun `it puts no limit on a whole transfer, so a long download can finish`() {
        assertEquals(0, client.callTimeoutMillis)
    }
}
