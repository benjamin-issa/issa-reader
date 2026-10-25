package com.benjaminissa.issareader.app.platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import com.benjaminissa.issareader.core.networking.MonitoredReachability
import com.benjaminissa.issareader.core.networking.Reachability

/**
 * Whether the server is plausibly reachable, from Android's default network.
 *
 * Online means the network can carry traffic at all (`INTERNET`), not that
 * Android has *validated* it: a home network with no route to the internet is
 * exactly where a Storyteller server often lives, and treating it as offline
 * would hold every queued write back from a server sitting on the same Wi-Fi.
 * Expensive means metered, or Data Saver on — the iPhone's `isExpensive` and
 * `isConstrained` together — which is what the Wi-Fi-only download switch
 * asks about.
 *
 * Updates arrive on the main thread, where the Swift monitor's hops land.
 */
class AndroidReachability private constructor(
    private val monitored: MonitoredReachability,
) : Reachability by monitored {
    companion object {
        fun start(context: Context): AndroidReachability {
            val reachability = AndroidReachability(MonitoredReachability())
            val manager = context.getSystemService(ConnectivityManager::class.java)
            val main = Handler(Looper.getMainLooper())
            fun publish(capabilities: NetworkCapabilities?) {
                val online = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
                val metered = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
                val saver = manager.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
                reachability.monitored.update(isOnline = online, isExpensive = online && (metered || saver))
            }
            publish(manager.getNetworkCapabilities(manager.activeNetwork))
            manager.registerDefaultNetworkCallback(
                object : ConnectivityManager.NetworkCallback() {
                    override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                        publish(capabilities)
                    }

                    override fun onLost(network: Network) {
                        publish(null)
                    }
                },
                main,
            )
            return reachability
        }
    }
}
