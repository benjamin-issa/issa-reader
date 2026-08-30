import Foundation

/// Reads and writes reading position.
///
/// The server's contract has two sharp edges, both verified against a running
/// instance:
///
/// - It rejects a write whose timestamp is older than the stored one **and**
///   one whose timestamp is equal but whose locator differs, so timestamps are
///   milliseconds. Second resolution causes avoidable conflicts.
/// - Writing a position silently moves the book's reading status: to "Reading"
///   below 98% and to "Read" at or above it. Callers should not also set status
///   by hand, and should expect it to change underneath them.
public struct ProgressService: Sendable {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    struct PositionBody: Codable, Sendable {
        let locator: ReadiumLocator
        let timestamp: Double
    }

    /// Epoch milliseconds, matching what the server stores and compares.
    public static func now() -> Double {
        (Date().timeIntervalSince1970 * 1000).rounded()
    }

    public func current(for bookUUID: String) async throws -> StoredPosition? {
        do {
            return try await client.get(Endpoint.positions(bookUUID))
        } catch StorytellerError.notFound {
            // No position yet simply means the book has not been opened.
            return nil
        }
    }

    /// Writes a position, reconciling if the server already has a newer one.
    ///
    /// Returns the position that ended up winning, so the caller can jump to it
    /// rather than silently continuing from a place the user has already moved
    /// past on another device.
    @discardableResult
    public func save(
        _ locator: ReadiumLocator,
        for bookUUID: String,
        timestamp: Double = ProgressService.now(),
    ) async throws -> StoredPosition? {
        do {
            try await client.post(
                Endpoint.positions(bookUUID),
                body: PositionBody(locator: locator, timestamp: timestamp),
            )
            return StoredPosition(uuid: nil, locator: locator, timestamp: timestamp,
                                  createdAt: nil, updatedAt: nil)
        } catch StorytellerError.positionConflict {
            // Another device is further along, or wrote a different locator at
            // the same instant. The server's copy wins; report it back.
            return try await current(for: bookUUID)
        }
    }
}
