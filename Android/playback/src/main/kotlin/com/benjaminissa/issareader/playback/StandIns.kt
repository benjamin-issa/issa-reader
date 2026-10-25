package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.instantOfEpochSeconds
import com.benjaminissa.issareader.core.model.Fnv1a
import com.benjaminissa.issareader.core.model.ReadiumLocator
import java.time.Instant

// STAND-IN, to be deleted. These are IssaCore's (`Model/Book.swift`'s
// `StoredPosition`, and `Model/BookIdentifier.swift`'s `isBareUUID` and
// `safePathComponent`), and belong in `:core` as `core.model.StoredPosition`
// and `String.isBareUuid` / `String.safePathComponent`. `:core` is being ported
// in parallel and had not ported them when `:playback` was, and `:playback`
// does not add to `:core`, so they live here in the same shape until it does;
// then this file goes and `ListeningResume.kt` and `AudioExtraction.kt` import
// the core ones instead. `StoredPosition` keeps only the fields the playback
// module reads; the core type adds `createdAt` and `updatedAt`.

/** A stored reading position, as embedded in a book payload. */
data class StoredPosition(
    val uuid: String? = null,
    val locator: ReadiumLocator,
    /**
     * Epoch milliseconds. The server rejects a write whose timestamp is older
     * than the stored one — and also one that is *equal* with a different
     * locator — so millisecond resolution matters.
     */
    val timestamp: Double,
) {
    /**
     * When this position was written, as an instant rather than a number.
     *
     * The trap this exists to close: [timestamp] is epoch **milliseconds**, and
     * `AudioAnchor.writtenAt` is epoch **seconds**. Both are `Double`, both are
     * named for the same idea, and comparing them directly with `>` is always
     * false for any two writes this decade — so a rule about which of the two
     * is newer would read as wired up while doing nothing at all.
     */
    val writtenAt: Instant get() = instantOfEpochSeconds(timestamp / 1000)
}

/**
 * The canonical 8-4-4-4-12 hexadecimal form, and nothing else.
 *
 * ASCII only, by byte: a "digit" of any other script names a file with
 * non-ASCII characters in it, and a second spelling of the identifier.
 */
internal val String.isBareUuid: Boolean
    get() {
        val groups = split('-')
        if (groups.size != 5) return false
        val widths = intArrayOf(8, 4, 4, 4, 12)
        for ((group, width) in groups.zip(widths.toList())) {
            if (group.length != width) return false
            if (!group.all { it in '0'..'9' || it in 'A'..'F' || it in 'a'..'f' }) return false
        }
        return true
    }

/**
 * This identifier as one path component that cannot escape its directory.
 *
 * Hashed rather than stripped, and hashed rather than refused, so that the path
 * that writes a file and the path that deletes it cannot disagree about where
 * it lives. FNV-1a, and byte-for-byte the spelling the Swift client ships:
 * files named `unsafe-<hash>` exist on devices, and must still be found.
 */
internal val String.safePathComponent: String
    get() = if (isBareUuid) this else "unsafe-${Fnv1a.hexadecimal(this)}"
