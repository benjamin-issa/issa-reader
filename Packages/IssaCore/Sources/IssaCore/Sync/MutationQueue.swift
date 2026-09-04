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

    /// Whether a drain is already in flight.
    ///
    /// `drain()` is called from `enqueue` (so, every debounced save), from the
    /// reachability hook, from `refreshLibrary` and on foreground, and it had
    /// no mutual exclusion: `pending()` never marked a row in flight, so two
    /// overlapping drains read the same rows and sent them twice, concurrently,
    /// in no defined order. Mark a book "Reading" and immediately "Read" and
    /// the two PUTs raced; whichever landed second won, so the server could
    /// end on the status the reader did not choose. Both also called
    /// `recordFailure` on failure, halving the effective abandon budget.
    private var isDraining = false

    /// Claims the right to drain, or declines because someone else holds it.
    func beginDraining() -> Bool {
        guard !isDraining else { return false }
        isDraining = true
        return true
    }

    func endDraining() { isDraining = false }

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
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT ordering, attempts, createdAt, payload FROM mutation WHERE bookUUID = ? AND kind = ?",
                arguments: [bookUUID, kind.rawValue],
            )
            if let ordering, let held = Self.heldOrdering(of: existing), ordering < held {
                // The queued write is newer than this one. Keeping it is the
                // whole point: it may be the only remaining copy of where the
                // reader actually is.
                return false
            }
            // The replacement inherits the failures and the age of what it
            // replaces. With a fresh count and a fresh timestamp on every
            // collapse, a position the server kept refusing was re-queued
            // every page turn as a brand-new item: it could never reach the
            // abandon limit, and it sat at the back of the drain order while
            // everything behind it waited on it forever.
            let attempts = existing?["attempts"] as Int? ?? 0
            let createdAt = existing?["createdAt"] as Double? ?? Date().timeIntervalSince1970
            try db.execute(
                sql: "DELETE FROM mutation WHERE bookUUID = ? AND kind = ?",
                arguments: [bookUUID, kind.rawValue],
            )
            try db.execute(
                sql: """
                    INSERT INTO mutation (bookUUID, kind, payload, createdAt, attempts, ordering)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [bookUUID, kind.rawValue, payload, createdAt, attempts, ordering],
            )
            return true
        }
    }

    /// How new the queued row is, from its column or from its payload.
    ///
    /// The guard above used to be `let held = existing?["ordering"] as Double?`,
    /// which silently skips the whole check when that column is NULL — and it
    /// is NULL for every row written before the `v4-mutation-ordering`
    /// migration, which added the column with no backfill. A reader who queued
    /// a position offline on the old build, upgraded, and took an out-of-order
    /// write before the queue drained had that row deleted and replaced by the
    /// older one. The doc two lines up calls it possibly the only remaining
    /// copy of where the reader is.
    ///
    /// The timestamp is already inside the encoded payload, so a row from
    /// before the migration can still say how new it is.
    private static func heldOrdering(of row: Row?) -> Double? {
        guard let row else { return nil }
        if let ordering = row["ordering"] as Double? { return ordering }
        guard let payload = row["payload"] as Data?,
              let position = try? JSONDecoder().decode(
                  MutationDrain.PositionPayload.self, from: payload)
        else { return nil }
        return position.timestamp
    }

    /// Blanks the ordering column, to stand in for a row written before the
    /// v4 migration added it. Tests only — there is no other way to produce a
    /// pre-migration row against a freshly-migrated database.
    func clearOrderingForTesting(bookUUID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE mutation SET ordering = NULL WHERE bookUUID = ?",
                arguments: [bookUUID])
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
        // One drain at a time. A second caller returning 0 immediately is
        // correct: the writes it would have sent are the ones already in
        // flight, and it will be re-triggered by whatever enqueues next.
        guard await queue.beginDraining() else { return 0 }
        let sent = await drainHoldingTheLock()
        // Released before returning, not from `defer { Task { … } }`. A
        // deferred Task releases *asynchronously*, so a caller draining twice
        // in a row — which `enqueue` does on every debounced save — found the
        // lock still held and got a spurious 0.
        await queue.endDraining()
        return sent
    }

    private func drainHoldingTheLock() async -> Int {
        guard let pending = try? await queue.pending(), !pending.isEmpty else { return 0 }
        var sent = 0

        for item in pending {
            do {
                try await send(item)
                try? await queue.remove(item.id)
                sent += 1
            } catch StorytellerError.positionConflict {
                // The server has something newer. Ours is obsolete, not failed.
                //
                // Logged, because this and the non-retryable branch below are
                // the only two places a write is thrown away, and they were the
                // only two that said nothing — so a server that refused every
                // position looked exactly like a client that never sent one.
                IssaLog.info("mutation superseded by server", [
                    "kind": String(describing: item.kind), "book": item.bookUUID,
                ])
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
                //
                // A discarded write is worth a line even when discarding is
                // correct: this is where a rejected locator shape would go, and
                // without it the position simply stops moving for no stated
                // reason.
                IssaLog.failure("sync mutation discarded", error, [
                    "kind": String(describing: item.kind), "book": item.bookUUID,
                ])
                try? await queue.remove(item.id)
            } catch {
                IssaLog.failure("sync mutation", error, ["kind": String(describing: item.kind)])
                // Anything else is worth another go later — but only a failure
                // that could implicate the write itself counts toward giving
                // up on it. Every offline drain used to count, and eight of
                // them — well under a minute of reading without signal, since
                // each debounced save triggers one — quietly deleted the head
                // of the queue.
                if countsTowardAbandonment(error),
                   (try? await queue.recordFailure(item.id)) == true {
                    // The third and last place a write is thrown away, and
                    // until this line the only one that said nothing.
                    IssaLog.failure("sync mutation abandoned", error, [
                        "kind": String(describing: item.kind), "book": item.bookUUID,
                    ])
                }
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

    /// Whether a failed attempt is evidence against the queued write itself.
    ///
    /// Abandonment exists for poisoned items: writes that will never send and,
    /// because the drain stops at its first failure, block every write behind
    /// them. A transport failure is not that — the request never reached the
    /// server, and a queue that outlives an offline weekend is the whole point
    /// of a durable one. A 429 is the server explicitly asking to be tried
    /// later; obeying must not cost the write. A 5xx *does* count — a
    /// judgement call: the server received exactly this payload and choked,
    /// and a payload that reliably breaks a route would otherwise sit at the
    /// head of the queue forever, while a server that is merely down mostly
    /// presents as transport failures — even behind a proxy's 502s, nothing is
    /// lost unless eight separate drains all land inside the same outage.
    /// Anything unrecognised (a payload that no longer decodes, say) fails
    /// identically every time, which is what poison means.
    private func countsTowardAbandonment(_ error: any Error) -> Bool {
        guard let storyteller = error as? StorytellerError else { return true }
        switch storyteller {
        case .transport, .server(status: 429, message: _):
            return false
        default:
            return true
        }
    }
}
