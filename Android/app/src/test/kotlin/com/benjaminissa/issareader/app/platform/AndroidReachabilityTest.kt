package com.benjaminissa.issareader.app.platform

import android.net.NetworkCapabilities
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.shadows.ShadowNetworkCapabilities

/**
 * What the Wi-Fi-only switch is told about the network. Data Saver is the
 * device's setting and cannot be turned on here; it acts only on a metered
 * network, so what is checked is that the answer rests on metering alone: an
 * unmetered network is never expensive.
 */
@RunWith(RobolectricTestRunner::class)
class AndroidReachabilityTest {
    private fun capabilities(vararg present: Int): NetworkCapabilities =
        ShadowNetworkCapabilities.newInstance().also { caps -> present.forEach { org.robolectric.Shadows.shadowOf(caps).addCapability(it) } }

    @Test
    fun `Wi-Fi is online and not expensive`() {
        val wifi = capabilities(NetworkCapabilities.NET_CAPABILITY_INTERNET, NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        assertTrue(AndroidReachability.isOnline(wifi))
        assertFalse(AndroidReachability.isExpensive(wifi))
    }

    @Test
    fun `a metered network is expensive`() {
        assertTrue(AndroidReachability.isExpensive(capabilities(NetworkCapabilities.NET_CAPABILITY_INTERNET)))
    }

    @Test
    fun `no network is neither online nor expensive`() {
        assertFalse(AndroidReachability.isOnline(null))
        assertFalse(AndroidReachability.isExpensive(null))
    }
}
