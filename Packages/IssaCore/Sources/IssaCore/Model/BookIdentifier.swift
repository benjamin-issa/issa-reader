import Foundation

/// Whether a server-supplied identifier is safe to put in a path.
///
/// Book uuids arrive as `String` from the catalogue and are then interpolated
/// straight into two kinds of path: a filename under `Books/`, and a URL path
/// component on every `/api/v2/books/{uuid}/…` route. Neither interpolation
/// escapes anything — `URL.appending(path:)` preserves `../` rather than
/// encoding or collapsing it, verified by running it — so a catalogue entry
/// whose uuid is `../../../Library/Preferences/x` lets the server choose the
/// path a downloaded file is written to, and lets it aim the `Authorization`
/// header at an arbitrary path on its own host once CFNetwork collapses the dot
/// segments.
///
/// The rule is a whitelist, not a blacklist. Stripping `..` invites the next
/// encoding that means the same thing; requiring the shape a uuid actually has
/// does not. `LibraryStore.filename(for:)` sets the precedent in this package
/// and states it plainly: "A server URL is not a filename; hash it rather than
/// trying to sanitise."
public extension String {
    /// The canonical 8-4-4-4-12 hexadecimal form, and nothing else.
    ///
    /// Deliberately stricter than `UUID(uuidString:)`, which also accepts a
    /// braced form and is lenient about case in ways that would let two
    /// spellings of one identifier name two different files.
    var isBareUUID: Bool {
        let groups = split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5 else { return false }
        let widths = [8, 4, 4, 4, 12]
        for (group, width) in zip(groups, widths) {
            guard group.count == width else { return false }
            guard group.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase || $0.isUppercase) })
            else { return false }
        }
        return true
    }

    /// This identifier as one path component that cannot escape its directory.
    ///
    /// The whitelist above says which identifiers are safe; this says what to do
    /// with the rest, and it is the half that had been copied rather than
    /// shared. `BookContentService.localURL` and `AskIndexStore.indexURL` each
    /// carried their own spelling of it, while `CustomFonts.extractedDirectory`
    /// and `AudioExtraction.defaultDirectory(for:)` carried none at all — and
    /// those two are the ones that name a *directory* and then delete it whole.
    /// A book id of `..` made `Fonts/../` and `Audio/../` both resolve to the
    /// storage root, so removing that book's derived files deleted every book,
    /// the catalogue, the logs and the reader's own imported fonts. The orphan
    /// sweep made it reachable without a hostile server: it decodes ids out of
    /// filenames it finds on disk, so a file named `..-ebook.epub` was enough.
    ///
    /// Hashed rather than stripped, for the reason the whitelist gives, and
    /// hashed rather than refused so that the path that writes a file and the
    /// path that deletes it cannot disagree about where it lives — a disagreement
    /// this app has already paid for once, when a validated read path and an
    /// unvalidated write path chose different names for the same download.
    ///
    /// FNV-1a, and byte-for-byte the spelling both call sites already shipped:
    /// files named `unsafe-<hash>` exist on devices, and must still be found.
    var safePathComponent: String {
        isBareUUID ? self : "unsafe-\(fnv1a64)"
    }

    /// 64-bit FNV-1a in hexadecimal. Not a security property — it is only here
    /// to be stable and to contain no separator — so a non-cryptographic hash
    /// with no dependency is the right size of tool.
    private var fnv1a64: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Data(utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

public extension Book {
    /// The uuid, when it is safe to build a path from.
    ///
    /// `nil` rather than a sanitised string: a caller that cannot name a file
    /// for this book should decline to, not write one somewhere unexpected.
    var pathSafeUUID: String? { uuid.isBareUUID ? uuid : nil }
}
