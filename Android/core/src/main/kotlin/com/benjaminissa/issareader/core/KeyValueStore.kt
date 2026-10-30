package com.benjaminissa.issareader.core

/**
 * Small preferences the client keeps between launches: the library's
 * arrangement, the downloads' Wi-Fi-only switch and their fence.
 *
 * What `UserDefaults` is to the Swift client, as an interface, because core
 * has no Android types in it. Synchronous, as `UserDefaults` is, since every
 * reader of these values asks at a moment it cannot wait: the app backs it
 * with DataStore by keeping the values in memory and persisting each write
 * behind it. [InMemoryKeyValueStore] is the one tests use.
 *
 * Blobs are stored as strings (JSON), which is what DataStore holds without
 * conversion.
 */
interface KeyValueStore {
    fun getString(key: String): String?

    /** Stores [value], or removes the key for null. */
    fun putString(key: String, value: String?)

    /** The stored flag, or false when there is none — `UserDefaults.bool(forKey:)`. */
    fun getBoolean(key: String): Boolean

    fun putBoolean(key: String, value: Boolean)

    /**
     * The stored flag, or null when the reader never chose — `object(forKey:) as? Bool`.
     *
     * [getBoolean] reads an absent key as off, which is right for a switch that
     * starts off and wrong for one that starts on: there the absence has to be
     * told from a choice.
     */
    fun getBooleanOrNull(key: String): Boolean?

    fun remove(key: String)
}

/** A [KeyValueStore] held in memory only: for tests, and for a caller that wants nothing kept. */
class InMemoryKeyValueStore : KeyValueStore {
    private val values = mutableMapOf<String, Any>()

    @Synchronized override fun getString(key: String): String? = values[key] as? String

    @Synchronized override fun putString(key: String, value: String?) {
        if (value == null) values.remove(key) else values[key] = value
    }

    @Synchronized override fun getBoolean(key: String): Boolean = values[key] as? Boolean ?: false

    @Synchronized override fun getBooleanOrNull(key: String): Boolean? = values[key] as? Boolean

    @Synchronized override fun putBoolean(key: String, value: Boolean) {
        values[key] = value
    }

    @Synchronized override fun remove(key: String) {
        values.remove(key)
    }
}
