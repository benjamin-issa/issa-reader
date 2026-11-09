package com.benjaminissa.issareader.core.model

/*
 * Whether a server-supplied identifier is safe to put in a path.
 *
 * Book uuids arrive as `String` from the catalogue and are then interpolated
 * straight into two kinds of path: a filename under `Books/`, and a URL path
 * component on every `/api/v2/books/{uuid}/…` route. Neither interpolation
 * escapes anything — Swift's `URL.appending(path:)` preserves `../` rather than
 * encoding or collapsing it, verified by running it, and `File(dir, name)`
 * keeps it too — so a catalogue entry whose uuid is
 * `../../../Library/Preferences/x` lets the server choose the path a
 * downloaded file is written to, and lets it aim the `Authorization` header at
 * an arbitrary path on its own host once the dot segments are collapsed.
 *
 * The rule is a whitelist, not a blacklist. Stripping `..` invites the next
 * encoding that means the same thing; requiring the shape a uuid actually has
 * does not. `LibraryStore.filename(for)` sets the precedent in this module and
 * states it plainly: "A server URL is not a filename; hash it rather than
 * trying to sanitise."
 */

/**
 * The canonical 8-4-4-4-12 hexadecimal form, and nothing else.
 *
 * Deliberately stricter than `UUID.fromString`, which also accepts groups of
 * other widths and would let two spellings of one identifier name two
 * different files.
 *
 * ASCII only, by character: `Char.isDigit` also admits the fullwidth forms and
 * a digit of any script, and each of those names a file with non-ASCII
 * characters in it, and a second spelling of the identifier. A combining mark
 * fails the width check, since it is a character of its own here.
 */
val String.isBareUuid: Boolean
    get() {
        val groups = split('-')
        if (groups.size != 5) return false
        val widths = intArrayOf(8, 4, 4, 4, 12)
        for ((index, group) in groups.withIndex()) {
            if (group.length != widths[index]) return false
            if (!group.all { it in '0'..'9' || it in 'A'..'F' || it in 'a'..'f' }) return false
        }
        return true
    }

/**
 * This identifier as one path component that cannot escape its directory.
 *
 * The whitelist above says which identifiers are safe; this says what to do
 * with the rest, and it is the half that had been copied rather than shared.
 * `BookContentService.localURL` and `AskIndexStore.indexURL` each carried
 * their own spelling of it, while `CustomFonts.extractedDirectory` and
 * `AudioExtraction.defaultDirectory(for:)` carried none at all — and those two
 * are the ones that name a *directory* and then delete it whole. A book id of
 * `..` made `Fonts/../` and `Audio/../` both resolve to the storage root, so
 * removing that book's derived files deleted every book, the catalogue, the
 * logs and the reader's own imported fonts. The orphan sweep made it reachable
 * without a hostile server: it decodes ids out of filenames it finds on disk,
 * so a file named `..-ebook.epub` was enough.
 *
 * Hashed rather than stripped, for the reason the whitelist gives, and hashed
 * rather than refused so that the path that writes a file and the path that
 * deletes it cannot disagree about where it lives — a disagreement this app
 * has already paid for once, when a validated read path and an unvalidated
 * write path chose different names for the same download.
 *
 * FNV-1a, and byte-for-byte the spelling the Swift client ships: files named
 * `unsafe-<hash>` exist on devices, and the two clients must agree.
 */
val String.safePathComponent: String
    get() = if (isBareUuid) this else "unsafe-${Fnv1a.hexadecimal(this)}"

/**
 * The uuid, when it is safe to build a path from.
 *
 * `null` rather than a sanitised string: a caller that cannot name a file for
 * this book should decline to, not write one somewhere unexpected.
 */
val Book.pathSafeUuid: String? get() = if (uuid.isBareUuid) uuid else null
