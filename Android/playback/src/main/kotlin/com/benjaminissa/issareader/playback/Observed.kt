package com.benjaminissa.issareader.playback

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

/**
 * Swift's `@Observable`, reduced to what a screen needs: a revision that moves
 * whenever an observed property changes.
 *
 * The Swift types in this module are `@Observable`, so every view that reads
 * `isPlaying` or `activeFragmentID` redraws when it moves, without a publisher
 * per property. A Compose screen gets the same by collecting [changes] and
 * reading the properties it draws; a property declared `by observed(…)` bumps
 * the revision when it is assigned a different value.
 *
 * The state itself stays main-thread-only, as the Swift types are
 * `@MainActor`. Only the revision is safe to read from anywhere.
 */
abstract class Observed {
    private val revision = MutableStateFlow(0L)

    /** Moves whenever an observed property of this object changes. */
    val changes: StateFlow<Long> = revision.asStateFlow()

    /** Bumps the revision by hand, for a change no delegated property sees. */
    protected fun changed() {
        revision.value += 1
    }

    /** A property whose writes are announced through [changes]. */
    protected fun <T> observed(initial: T): ReadWriteProperty<Observed, T> = object : ReadWriteProperty<Observed, T> {
        private var value = initial

        override fun getValue(thisRef: Observed, property: KProperty<*>): T = value

        override fun setValue(thisRef: Observed, property: KProperty<*>, value: T) {
            if (this.value == value) return
            this.value = value
            thisRef.changed()
        }
    }
}
