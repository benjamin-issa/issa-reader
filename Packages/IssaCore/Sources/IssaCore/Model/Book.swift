import Foundation

/// A book as returned by `GET /api/v2/books` and `GET /api/v2/books/{uuid}`.
///
/// Modelled against live JSON from a `web-v2.14.21` server. Two things about the
/// list endpoint shape the whole client:
///
/// 1. It takes no query parameters and returns the entire library in one
///    unpaginated array. We ingest it wholesale and derive search, facets and
///    shelves locally, which is both faster and works offline.
/// 2. It embeds this user's `position` and `status`, so a single request yields
///    the catalogue *and* all reading progress. There is no separate progress
///    fetch on first sync.
public struct Book: Codable, Hashable, Sendable, Identifiable {
    /// Stable identity. `id` below is a legacy integer kept for older clients;
    /// always key on `uuid`.
    public var uuid: String
    /// Legacy auto-increment id, kept by the server for pre-uuid clients.
    /// Never key on it.
    public var legacyID: Int?

    public var title: String
    public var subtitle: String?
    public var description: String?
    public var language: String?
    public var publicationDate: FlexibleDate?

    /// Server-wide rating, distinct from this user's rating (`GET /books/{id}/rating`).
    public var rating: Double?
    /// Total audio duration in seconds, when the book has audio.
    public var duration: Double?
    public var pageCount: Int?
    public var assetDir: String?

    public var alignedAt: FlexibleDate?
    public var alignedWith: String?
    public var alignedByStorytellerVersion: String?

    public var createdAt: FlexibleDate?
    public var updatedAt: FlexibleDate?

    // Creators are split by role server-side: `aut` and `nrt` get their own
    // arrays, and everything else (translator, editor, illustrator…) lands in
    // `creators` carrying an explicit `role`.
    public var authors: [Creator]
    public var narrators: [Creator]
    public var creators: [Creator]

    public var series: [SeriesMembership]
    public var tags: [Tag]
    public var collections: [Collection]
    public var identifiers: [Identifier]

    /// Per-user reading status ("To read" / "Reading" / "Read"). Present only
    /// when the request is authenticated.
    public var status: Status?
    /// Per-user reading position. Present only when authenticated, and `nil`
    /// until the book has been opened at least once.
    public var position: StoredPosition?

    public var ebook: EbookFormat?
    public var audiobook: AudiobookFormat?
    public var readaloud: ReadaloudFormat?

    public var id: String { uuid }

    private enum CodingKeys: String, CodingKey {
        case uuid
        case legacyID = "id"
        case title, subtitle, description, language, publicationDate
        case rating, duration, pageCount, assetDir
        case alignedAt, alignedWith, alignedByStorytellerVersion
        case createdAt, updatedAt
        case authors, narrators, creators
        case series, tags, collections, identifiers
        case status, position
        case ebook, audiobook, readaloud
    }
}

public extension Book {
    /// The formats this book is actually available in.
    var availableFormats: Set<BookFormat> {
        var formats: Set<BookFormat> = []
        if ebook != nil { formats.insert(.ebook) }
        if audiobook != nil { formats.insert(.audiobook) }
        if readaloud != nil { formats.insert(.readaloud) }
        return formats
    }

    /// True when the book has audio synchronised to its text.
    var hasReadalong: Bool { readaloud?.filepath != nil }

    /// Book-level completion, 0...1, from the stored Readium locator.
    var progress: Double? { position?.locator.totalProgression }

    /// Display byline. Falls back to narrators only if there is no author at all.
    var byline: String {
        let names = authors.isEmpty ? narrators.map(\.name) : authors.map(\.name)
        return names.joined(separator: ", ")
    }
}

public enum BookFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case ebook
    case audiobook
    case readaloud
}

public struct Creator: Codable, Hashable, Sendable, Identifiable {
    public var uuid: String
    /// Legacy auto-increment id; never key on it.
    public var legacyID: Int?
    public var name: String
    /// Sort form, e.g. "Carroll, Lewis".
    public var fileAs: String?
    /// MARC relator code, present only in the mixed `creators` array.
    /// `aut` and `nrt` are pre-split into their own arrays.
    public var role: String?
    public var createdAt: FlexibleDate?
    public var updatedAt: FlexibleDate?

    public var id: String { uuid }

    private enum CodingKeys: String, CodingKey {
        case uuid
        case legacyID = "id"
        case name, fileAs, role, createdAt, updatedAt
    }
}

public struct SeriesMembership: Codable, Hashable, Sendable, Identifiable {
    public var uuid: String
    public var name: String
    public var featured: Bool?
    /// Position within the series; fractional values are legal (e.g. 1.5 for a novella).
    public var position: Double?
    public var createdAt: FlexibleDate?
    public var updatedAt: FlexibleDate?

    public var id: String { uuid }
}

public struct Tag: Codable, Hashable, Sendable, Identifiable {
    public var uuid: String
    public var name: String
    public var createdAt: FlexibleDate?
    public var updatedAt: FlexibleDate?

    public var id: String { uuid }
}

public struct Collection: Codable, Hashable, Sendable, Identifiable {
    public var uuid: String
    public var name: String
    public var description: String?
    public var isPublic: Bool?
    public var createdAt: FlexibleDate?
    public var updatedAt: FlexibleDate?

    public var id: String { uuid }

    private enum CodingKeys: String, CodingKey {
        case uuid, name, description
        case isPublic = "public"
        case createdAt, updatedAt
    }
}

public struct Status: Codable, Hashable, Sendable, Identifiable {
    public var uuid: String
    public var name: String
    public var isDefault: Bool?
    public var createdAt: FlexibleDate?
    public var updatedAt: FlexibleDate?

    public var id: String { uuid }

    /// The three statuses a default install ships with. Compared by name because
    /// the uuids are generated per-server and an admin may add their own.
    public static let toReadName = "To read"
    public static let readingName = "Reading"
    public static let readName = "Read"
}

public struct Identifier: Codable, Hashable, Sendable {
    public var uuid: String?
    /// e.g. "isbn", "asin", "audible".
    public var type: String?
    public var value: String?
}

/// A stored reading position, as embedded in a book payload.
public struct StoredPosition: Codable, Hashable, Sendable {
    public var uuid: String?
    public var locator: ReadiumLocator
    /// Epoch milliseconds. The server rejects a write whose timestamp is older
    /// than the stored one — and also one that is *equal* with a different
    /// locator — so millisecond resolution matters.
    public var timestamp: Double
    public var createdAt: FlexibleDate?
    public var updatedAt: FlexibleDate?
}

// MARK: - Formats

public struct EbookFormat: Codable, Hashable, Sendable {
    public var uuid: String
    public var filepath: String?
    public var missing: Bool?
    public var isEpub2: Bool?
    public var fingerprint: String?
    public var pageCount: Int?
    public var fileSize: Int?
    public var identifiers: [Identifier]?
    public var createdAt: FlexibleDate?
    public var updatedAt: FlexibleDate?
}

public struct AudiobookFormat: Codable, Hashable, Sendable {
    public var uuid: String
    public var filepath: String?
    public var missing: Bool?
    public var fingerprint: String?
    /// Seconds.
    public var duration: Double?
    public var fileSize: Int?
    public var identifiers: [Identifier]?
    public var createdAt: FlexibleDate?
    public var updatedAt: FlexibleDate?
}

/// The aligned EPUB: text plus embedded audio plus SMIL media overlays.
public struct ReadaloudFormat: Codable, Hashable, Sendable {
    public var uuid: String
    public var filepath: String?
    public var missing: Bool?
    public var isEpub2: Bool?
    /// Alignment pipeline state: CREATED, QUEUED, PROCESSING, STOPPED, ERROR, ALIGNED.
    public var status: String?
    public var currentStage: String?
    public var stageProgress: Double?
    public var queuePosition: Int?
    public var restartPending: Bool?
    public var fingerprint: String?
    public var pageCount: Int?
    public var duration: Double?
    public var fileSize: Int?
    public var identifiers: [Identifier]?
    public var createdAt: FlexibleDate?
    public var updatedAt: FlexibleDate?

    /// Only an `ALIGNED` readaloud has finished the pipeline; the rest are
    /// mid-flight or failed.
    ///
    /// Note that this is NOT sufficient to conclude the book has usable
    /// narration. Observed on a real server: when the aligner cannot locate a
    /// chapter's text in the transcript — which happens when the audio covers
    /// only part of the book, or the spine documents are far larger than the
    /// tracks — it writes the sentence markup, records `media:duration` of
    /// 00:00:00, attaches no media overlays at all, and still reports ALIGNED.
    /// The only trustworthy test is whether the downloaded EPUB yields a
    /// non-empty timeline.
    public var isAligned: Bool { status == "ALIGNED" }
}
