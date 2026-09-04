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
}

public extension Book {
    /// The uuid, when it is safe to build a path from.
    ///
    /// `nil` rather than a sanitised string: a caller that cannot name a file
    /// for this book should decline to, not write one somewhere unexpected.
    var pathSafeUUID: String? { uuid.isBareUUID ? uuid : nil }
}
