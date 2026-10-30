package com.benjaminissa.issareader.app.platform

import android.content.SharedPreferences
import com.benjaminissa.issareader.core.KeyValueStore

/**
 * The client's small preferences, kept as `UserDefaults` keeps them on iOS:
 * synchronously readable, written through in the background.
 *
 * `SharedPreferences` rather than DataStore because its contract is the one
 * [KeyValueStore] states — a read answers at once from memory, and a write is
 * visible immediately and persisted after — which is what every caller in core
 * expects of `UserDefaults`.
 */
class SharedPreferencesKeyValueStore(private val preferences: SharedPreferences) : KeyValueStore {
    override fun getString(key: String): String? = preferences.getString(key, null)

    override fun putString(key: String, value: String?) {
        preferences.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }

    override fun getBoolean(key: String): Boolean = preferences.getBoolean(key, false)

    override fun getBooleanOrNull(key: String): Boolean? =
        if (preferences.contains(key)) preferences.getBoolean(key, false) else null

    override fun putBoolean(key: String, value: Boolean) {
        preferences.edit().putBoolean(key, value).apply()
    }

    override fun remove(key: String) {
        preferences.edit().remove(key).apply()
    }
}
