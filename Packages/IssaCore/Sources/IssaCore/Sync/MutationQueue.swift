import Foundation
import GRDB

/// Writes that have not reached the server yet.
///
/// Every change a reader makes — where they got to, which shelf a book is on,
/// what they rated it — is recorded here *before* the network is attempted, and
/// drained when there is a connection. Without it, a chapter read on a train is
/// simply lost, and a status set in a lift silently rolls back.
///
/// Repeated positions for the same book collapse to the newest: a reader who
/// turns forty pages offline should send one position, not forty.
public actor MutationQueue {
    public enum Kind: String, Codable, Sendable {
        case position
        case status
        case rating
    }

    public struct Pending: Sendable, Hashable {
        public let id: Int64
        public let bookUUID: String
        public let kind: Kind
        public let payload: Data
        public let createdAt: Date
        public let attempts: Int
    }

    private let dbQueue: DatabaseQueue

    public init(store: LibraryStore) throws {
        // This opens a second connection to the same file `LibraryStore`
        // already has open — the queue and the catalogue live in one SQLite
        // database, but as two independent `DatabaseQueue`s there is no shared
        // in-process lock between them. GRDB's default `busyMode` is
        // `.immediateError`, so without this, a position write racing a
        // catalogue refresh (both routinely concurrent: `AppModel` enqueues a
        // position from the reader while a background `Task` calls
        // `replaceCatalogue`) throws `SQLITE_BUSY` the instant the two
        // connections collide — and every caller of `enqueue` wraps it in
        // `try?`, so the write is discarded with no error and no retry. Giving
        // this connection the same timeout `LibraryStore` already uses for
        // exactly this kind of contention turns that into a five-second wait
        // instead of a silent loss.
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        dbQueue = try DatabaseQueue(path: store.url.path, configuration: configuration)
    }

    /// Records an intent. Positions replace any earlier pending position for the
    /// same book; status and rating likewise, since only the latest matters.
    ///
    /// - Parameter supersedes: a caller-supplied ordering value — for a position,
    ///   the timestamp the server will compare. A pending write is replaced only
    ///   by one at least as new; an older one is dropped rather than allowed to
    ///   overwrite it. Without this, a write generated out of order erased a good
    ///   one that had not yet drained, and the queue was the only copy of it.
    ///   `nil` keeps the unconditional collapse, which is right for status and
    ///   rating: there the newest call always wins by definition.
    /// - Returns: whether anything was recorded.
    @discardableResult
    public func enqueue(
        _ kind: Kind, bookUUID: String, payload: Data, supersedes ordering: Double? = nil,
    ) throws -> Bool {
        try dbQueue.write { db in
            if let ordering,
               let existing = try Row.fetchOne(
                   db,
                   sql: "SELECT ordering FROM mutation WHERE bookUUID = ? AND kind = ?",
                   arguments: [bookUUID, kind.rawValue],
               ),
               let held = existing["ordering"] as Double?,
               ordering < held {
                // The queued write is newer than this one. Keeping it is the
                // whole point: it may be the only remaining copy of where the
                // reader actually is.
                return false
            }
            try db.execute(
                sql: "DELETE FROM mutation WHERE bookUUID = ? AND kind = ?",
                arguments: [bookUUID, kind.rawValue],
            )
            try db.execute(
                sql: """
                    INSERT INTO mutation (bookUUID, kind, payload, createdAt, attempts, ordering)
                    VALUES (?, ?, ?, ?, 0, ?)
                    """,
                arguments: [
                    bookUUID, kind.rawValue, payload, Date().timeIntervalSince1970, ordering,
                ],
            )
            return true
        }
    }

    public func pending() throws -> [Pending] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM mutation ORDER BY createdAt ASC").compactMap { row in
                guard let kind = Kind(rawValue: row["kind"] as String) else { return nil }
                return Pending(
                    id: row["id"],
                    bookUUID: row["bookUUID"],
                    kind: kind,
                    payload: row["payload"],
                    createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                    attempts: row["attempts"],
                )
            }
        }
    }

    public func remove(_ id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM mutation WHERE id = ?", arguments: [id])
        }
    }

    /// Records a failed attempt, and gives up after enough of them.
    ///
    /// A write the server keeps refusing — a book deleted server-side, a
    /// permission revoked — must not be retried forever, or it blocks every
    /// later write behind it.
    public func recordFailure(_ id: Int64, abandonAfter limit: Int = 8) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE mutation SET attempts = attempts + 1 WHERE id = ?", arguments: [id])
            let attempts = try Int.fetchOne(
                db, sql: "SELECT attempts FROM mutation WHERE id = ?", arguments: [id]) ?? 0
            if attempts >= limit {
                try db.execute(sql: "DELETE FROM mutation WHERE id = ?", arguments: [id])
                return true
            }
            return false
        }
    }

    public var count: Int {
        get throws { try dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM mutation") ?? 0 } }
    }

    public func removeAll() throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM mutation") }
    }
}

/// Sends what the queue holds, and keeps what it cannot send.
public struct MutationDrain: Sendable {
    private let queue: MutationQueue
    private let client: APIClient

    public init(queue: MutationQueue, client: APIClient) {
        self.queue = queue
        self.client = client
    }

    public struct PositionPayload: Codable, Sendable {
        public let locator: ReadiumLocator
        public let timestamp: Double
        public init(locator: ReadiumLocator, timestamp: Double) {
            self.locator = locator
            self.timestamp = timestamp
        }
    }

    public struct StatusPayload: Codable, Sendable {
        public let status: String
        public init(status: String) { self.status = status }
    }

    public struct RatingPayload: Codable, Sendable {
        public let rating: Double?
        public init(rating: Double?) { self.rating = rating }
    }

    /// Attempts every pending write, oldest first.
    ///
    /// - Returns: how many were accepted.
    @discardableResult
    public func drain() async -> Int {
        guard let pending = try? await queue.pending(), !pending.isEmpty else { return 0 }
        var sent = 0

        for item in pending {
            do {
                try await send(item)
                try? await queue.remove(item.id)
                sent += 1
            } catch StorytellerError.positionConflict {
                // The server has something newer. Ours is obsolete, not failed.
                try? await queue.remove(item.id)
            } catch StorytellerError.notAuthenticated {
                // Not this item's problem — the whole session is bad, and every
                // later item would fail identically. Keeping it queued, rather
                // than falling into the `!isRetryable` branch below and
                // discarding it, means a write that would have succeeded once
                // signed in again is not lost. Stopping the loop is what keeps
                // an expired token from silently emptying the entire backlog in
                // one pass — the removal below has no `break`, so before this
                // case existed the first 401 deleted everything behind it too.
                break
            } catch let error as StorytellerError where !error.isRetryable {
                // A refusal specific to this item that will not change on
                // retry — the book was deleted server-side, or a permission was
                // revoked for it. Genuinely per-item, unlike the auth case
                // above, so the rest of the queue still deserves its turn.
                try? await queue.remove(item.id)
            } catch {
                IssaLog.failure("sync mutation", error, ["kind": String(describing: item.kind)])
                // Anything else is worth another go later, up to a limit.
                _ = try? await queue.recordFailure(item.id)
                // Stop on the first genuine failure: the connection is probably
                // gone, and hammering the rest achieves nothing.
                break
            }
        }
        return sent
    }

    private func send(_ item: MutationQueue.Pending) async throws {
        switch item.kind {
        case .position:
            let payload = try JSONDecoder().decode(PositionPayload.self, from: item.payload)
            try await client.post(Endpoint.positions(item.bookUUID), body: payload)
        case .status:
            let payload = try JSONDecoder().decode(StatusPayload.self, from: item.payload)
            try await client.put(Endpoint.status(item.bookUUID), body: payload)
        case .rating:
            let payload = try JSONDecoder().decode(RatingPayload.self, from: item.payload)
            if let rating = payload.rating {
                try await client.put(
                    Endpoint.rating(item.bookUUID),
                    body: LibraryMutationService.Rating(rating: rating),
                )
            } else {
                try await client.delete(Endpoint.rating(item.bookUUID))
            }
        }
    }
}
