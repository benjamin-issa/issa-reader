import Foundation

/// Writes the per-user state a reader actually changes: reading status and
/// their own rating.
///
/// Both are per-user rather than per-book — two people sharing a server keep
/// separate shelves and separate ratings.
public struct LibraryMutationService: Sendable {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    // MARK: - Reading status

    struct StatusBody: Codable, Sendable { let status: String }
    struct BulkStatusBody: Codable, Sendable { let books: [String]; let status: String }

    /// Moves a book to a status.
    ///
    /// Worth knowing: the server also moves status on its own whenever a reading
    /// position is written — to "Reading" below 98% and "Read" at or above it.
    /// A manual choice can therefore be overwritten by simply continuing to
    /// read, which is usually what someone wants but is surprising if they have
    /// just marked something "To read".
    public func setStatus(_ statusUUID: String, for bookUUID: String) async throws {
        try await client.put(Endpoint.status(bookUUID), body: StatusBody(status: statusUUID))
    }

    /// Moves several books at once, for multi-select in the library.
    public func setStatus(_ statusUUID: String, forBooks bookUUIDs: [String]) async throws {
        guard !bookUUIDs.isEmpty else { return }
        try await client.put(
            Endpoint.bulkStatus,
            body: BulkStatusBody(books: bookUUIDs, status: statusUUID),
        )
    }

    // MARK: - Rating

    public struct Rating: Codable, Hashable, Sendable {
        /// 0...5. The server rejects anything outside that range.
        public var rating: Double?
        public var review: String?

        public init(rating: Double? = nil, review: String? = nil) {
            self.rating = rating
            self.review = review
        }
    }

    public func rating(for bookUUID: String) async throws -> Rating? {
        do {
            return try await client.get(Endpoint.rating(bookUUID))
        } catch StorytellerError.notFound {
            // Unrated, which is not an error.
            return nil
        }
    }

    /// Sets this user's rating.
    ///
    /// The server answers 405 — not 400 — for an out-of-range value or an empty
    /// body, so the range is enforced here and an empty write is turned into a
    /// delete rather than sent.
    public func setRating(_ value: Double?, review: String? = nil, for bookUUID: String) async throws {
        guard value != nil || review != nil else {
            try await clearRating(for: bookUUID)
            return
        }
        let clamped = value.map { min(max($0, 0), 5) }
        try await client.put(
            Endpoint.rating(bookUUID),
            body: Rating(rating: clamped, review: review),
        )
    }

    public func clearRating(for bookUUID: String) async throws {
        try await client.delete(Endpoint.rating(bookUUID))
    }
}
