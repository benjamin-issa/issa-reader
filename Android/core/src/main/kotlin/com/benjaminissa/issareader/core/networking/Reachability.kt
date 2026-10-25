package com.benjaminissa.issareader.core.networking

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Whether the server is plausibly reachable.
 *
 * Deliberately only a hint. The server is usually on a LAN, so "the device has
 * a network" says little about whether *this* server answers — a phone on
 * cellular is online and cannot see a home server at all. It is used to decide
 * when to retry queued writes and what to tell the reader, never to refuse to
 * try.
 *
 * An interface, because what watches the network is the platform's: the
 * Android app implements it over `ConnectivityManager`, most simply by feeding
 * a [MonitoredReachability] from a network callback.
 */
interface Reachability {
    val isOnline: StateFlow<Boolean>

    /**
     * True on a metered connection — cellular, or a hotspot the system marks
     * as such — so large downloads can be held back when the reader has asked
     * for Wi-Fi only.
     */
    val isExpensive: StateFlow<Boolean>

    /** Fired on each transition to online, for draining queued work. */
    var onBecameOnline: (() -> Unit)?
}

/**
 * A [Reachability] the platform tells what the network is doing.
 *
 * The app calls [update] with each path change (from the main thread, which is
 * where Swift's hops to the main actor land); a transition from offline to
 * online fires [onBecameOnline], once. Online until told otherwise, as the
 * Swift type starts.
 */
class MonitoredReachability : Reachability {
    private val online = MutableStateFlow(true)
    private val expensive = MutableStateFlow(false)

    override val isOnline: StateFlow<Boolean> = online.asStateFlow()
    override val isExpensive: StateFlow<Boolean> = expensive.asStateFlow()
    override var onBecameOnline: (() -> Unit)? = null

    /**
     * One path update: whether the network can carry traffic, and whether it
     * is metered or constrained.
     */
    fun update(isOnline: Boolean, isExpensive: Boolean) {
        val wasOffline = !online.value
        online.value = isOnline
        expensive.value = isExpensive
        if (isOnline && wasOffline) onBecameOnline?.invoke()
    }
}
