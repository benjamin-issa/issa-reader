package com.benjaminissa.issareader.playback.android

import android.content.Context
import androidx.car.app.connection.CarConnection
import androidx.lifecycle.Observer

/**
 * Whether a car is connected: CarPlay's scene connecting and disconnecting,
 * as Android tells it.
 *
 * Two witnesses. The authoritative one is the car app library's
 * [CarConnection], which Android Auto answers for the whole phone: projecting
 * or not. The other is Android Auto's own controller connecting to this app's
 * session — the fallback, for an Android Auto that does not answer
 * [CarConnection] at all. Once [CarConnection] has once said "projecting" it is
 * trusted alone, because a controller can stay bound for minutes after the car
 * has gone, and the end of a drive is what hands the book back to the reader.
 *
 * Remembered rather than only announced, as `CarPlayBridge.surface` is: the
 * connection is state, and [isConnected] is what a late listener reads.
 *
 * Main-thread only.
 *
 * @param onChange told each time the answer changes, never twice the same.
 */
class CarPresence(private val onChange: (Boolean) -> Unit) {
    var isConnected: Boolean = false
        private set

    private var projecting = false
    private var projectionWitnessed = false
    private val carControllers = mutableSetOf<Any>()

    /** [CarConnection]'s answer: one of its `CONNECTION_TYPE_*` constants. */
    fun connectionTypeChanged(type: Int) {
        projecting = type == CarConnection.CONNECTION_TYPE_PROJECTION || type == CarConnection.CONNECTION_TYPE_NATIVE
        if (projecting) projectionWitnessed = true
        update()
    }

    /** A car's controller connected; [key] identifies it until it goes. */
    fun carControllerConnected(key: Any) {
        carControllers.add(key)
        update()
    }

    fun carControllerDisconnected(key: Any) {
        carControllers.remove(key)
        update()
    }

    private fun update() {
        val connected = projecting || (!projectionWitnessed && carControllers.isNotEmpty())
        if (connected == isConnected) return
        isConnected = connected
        onChange(connected)
    }

    companion object {
        /**
         * Feeds [presence] from [CarConnection] for as long as the returned
         * handle stays open. Observed forever rather than with a lifecycle:
         * the car comes and goes whether or not any screen exists.
         */
        fun watch(context: Context, presence: CarPresence): AutoCloseable {
            val type = CarConnection(context).type
            val observer = Observer<Int> { presence.connectionTypeChanged(it ?: CarConnection.CONNECTION_TYPE_NOT_CONNECTED) }
            type.observeForever(observer)
            return AutoCloseable { type.removeObserver(observer) }
        }
    }
}
