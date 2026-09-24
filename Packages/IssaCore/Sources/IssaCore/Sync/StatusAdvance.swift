import Foundation

/// The status a position write should move a book to, when the server will not.
///
/// Storyteller's own rule, in `upsertPosition` (`database/positions.ts`): a
/// book whose status is empty or "To read" moves to "Reading" below 98%, and one
/// that is empty, "To read" or "Reading" moves to "Read" at 98% or more. 3.x
/// still intends that — its log line reads "Status is empty or To read" — but
/// applies it as an UPDATE of the book's status row, and a book with no status
/// has no row. The UPDATE matches nothing, and the book stays unfiled however
/// far it is read (reproduced against 3.0.0-beta.40). `PUT
/// /books/{uuid}/status` inserts a missing row, so writing the status the
/// server meant to restores its rule exactly.
///
/// Only the empty case. A book already at "To read" or "Reading" has a row,
/// the server advances it itself, and writing it here as well would race the
/// server to the same answer for nothing. Any other status — "Read", or one an
/// admin made — is the reader's choice and is left alone, as the server does.
///
/// A known 2.x server is excluded, although it would never fire there anyway:
/// 2.x gives every book a status row for every reader, and its position write
/// throws without one, so a positionable book never arrives with no status.
/// Excluding it keeps the rule from doing anything 2.x did not. An unknown
/// generation is allowed: detection runs after sign-in, and the first launch
/// after a server upgrade may be an offline one, where the positions written
/// are exactly the ones 3.x will not advance.
public enum StatusAdvance {
    /// The server's line between reading and read, inclusive on the read side.
    /// Shared with `LibraryArrangement.stage(of:)`, which shelves a book with
    /// no status the way the server would have filed it.
    public static let finishedThreshold = 0.98

    /// - Parameters:
    ///   - locator: the position just written.
    ///   - current: the book's status as this device holds it.
    ///   - generation: the detected server generation, nil while unknown.
    ///   - statuses: the server's statuses, from `GET /api/v2/statuses`.
    /// - Returns: the status to set, or nil to leave it to the server. Also
    ///   nil when `statuses` has none by the built-in name — not loaded yet,
    ///   or a server without it — because guessing at a replacement would
    ///   file the book somewhere the server never would.
    public static func statusToSet(
        after locator: ReadiumLocator,
        current: Status?,
        generation: ServerGeneration?,
        statuses: [Status],
    ) -> Status? {
        guard current == nil, generation != .v2 else { return nil }
        // The server's own default for a locator with no progression.
        let progression = locator.locations?.totalProgression ?? 0
        let name = progression >= finishedThreshold ? Status.readName : Status.readingName
        return statuses.first { $0.name == name }
    }
}
