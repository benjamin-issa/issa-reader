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
    /// Ratings gathered from external sources, keyed to those identifiers.
    /// Absent on servers with no external source configured.
    public var externalData: [ExternalData]?

    /// Per-user reading status ("To read" / "Reading" / "Read"). Present only
    /// when the request is authenticated.
    ///
    /// The server also changes this on its own when a reading position is
    /// written, so a locally-set value can be superseded by simply reading on.
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
        case series, tags, collections, identifiers, externalData
        case status, position
        case ebook, audiobook, readaloud
    }
}

public extension Book {
    /// The formats this book is actually available in.
    /// Every format the server has a row for, whether or not it can serve it.
    /// For anything user-facing prefer `servableFormats`.
    var availableFormats: Set<BookFormat> {
        var formats: Set<BookFormat> = []
        if ebook != nil { formats.insert(.ebook) }
        if audiobook != nil { formats.insert(.audiobook) }
        if readaloud != nil { formats.insert(.readaloud) }
        return formats
    }

    /// True when the book has audio synchronised to its text.
    var hasReadalong: Bool { readaloud?.filepath != nil }

    /// The formats the server can actually serve, as opposed to the rows it
    /// happens to have created.
    ///
    /// Distinct from `availableFormats`, which is a bare `!= nil` check: the
    /// server creates a readaloud row when alignment is merely *requested*, so
    /// a book can carry one with no file behind it. A badge promising narration
    /// the server cannot serve is a lie the reader only discovers after tapping.
    var servableFormats: Set<BookFormat> {
        var formats: Set<BookFormat> = []
        if ebook != nil, ebook?.missing != true { formats.insert(.ebook) }
        if audiobook?.filepath != nil, audiobook?.missing != true { formats.insert(.audiobook) }
        if readaloud?.filepath != nil, readaloud?.missing != true { formats.insert(.readaloud) }
        return formats
    }

    /// Whether opening this book leads to the reader at all. An audiobook-only
    /// book has no on-screen text, so a "resume reading" request for it lands on
    /// the detail screen instead — callers use this to keep that promise honest.
    var isReadable: Bool {
        servableFormats.contains(.ebook) || servableFormats.contains(.readaloud)
    }

    /// Book-level completion, 0...1, from the stored Readium locator.
    var progress: Double? { position?.locator.totalProgression }

    /// Adopts a position the app has just written itself.
    ///
    /// Refuses one older than the position already held. The server applies
    /// exactly this rule to a write, and without it here a save completing out
    /// of order — the mutation queue draining an earlier page after a later one
    /// — makes the Continue card walk backwards.
    mutating func adopt(position locator: ReadiumLocator, timestamp: Double) {
        if let position, position.timestamp > timestamp { return }
        position = StoredPosition(
            uuid: position?.uuid, locator: locator, timestamp: timestamp)
    }

    /// Takes everything the server says about this book except a reading
    /// position older than the one already held.
    ///
    /// The catalogue is refetched wholesale, and a refetch that predates a write
    /// still sitting in the mutation queue carries a stale `position`. Assigning
    /// it verbatim walks the Continue card — and the place the reader resumes at
    /// — backwards by however long the queue has been holding.
    ///
    /// Position only. Title, formats, alignment, tags and page counts are all
    /// newer server truth and are taken as given; a `status` one refresh stale is
    /// cosmetic, where a position one refresh stale is the bug this exists for.
    func reconciled(with fresh: Book) -> Book {
        guard let mine = position else { return fresh }
        var merged = fresh
        // A server that has never heard of our position must not clear it: the
        // write may simply not have drained yet.
        if fresh.position.map({ mine.timestamp > $0.timestamp }) ?? true {
            merged.position = mine
        }
        return merged
    }

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

public struct Identifier: Codable, Hashable, Sendable, Identifiable {
    /// The identifier *type's* uuid: the server serialises the type joined with
    /// the value, so this is not unique per book.
    public var uuid: String?
    /// Slug, e.g. `isbn-13`, `audible`, `hardcover-book-slug`.
    public var kind: String?
    /// Display name, e.g. "ISBN-13", "Audible ASIN".
    public var name: String?
    /// A URL with `{value}` to substitute, when the type has one configured.
    public var urlTemplate: String?
    public var externalSourceUuid: String?
    public var value: String?

    public var id: String { (uuid ?? "") + (value ?? "") }

    /// Where to look this identifier up, when the server knows.
    public var url: URL? {
        guard let urlTemplate, let value else { return nil }
        let filled = urlTemplate.replacingOccurrences(of: "{value}", with: value)
        return URL(string: filled)
    }

    /// What to call this to a reader. Falls back to the slug, then to nothing:
    /// a value with no label at all is worse than a slightly ugly one.
    public var label: String {
        if let name, !name.isEmpty { return name }
        if let kind, !kind.isEmpty { return kind.uppercased() }
        return "Identifier"
    }
}

/// A rating carried in from somewhere else — Hardcover, at the time of writing.
///
/// The scale travels with the rating because sources do not agree on one: the
/// server records min and max per source precisely so a client does not have to
/// assume five stars.
public struct ExternalData: Codable, Hashable, Sendable, Identifiable {
    public var uuid: String
    public var rating: Double
    public var fetchedAt: FlexibleDate?
    public var sourceUuid: String?
    public var sourceName: String?
    public var sourceColor: String?
    public var sourceUrl: String?
    public var sourceRatingIcon: String?
    public var sourceRatingMin: Double?
    public var sourceRatingMax: Double?

    public var id: String { uuid }

    /// The rating as a fraction of its own scale, for drawing it on ours.
    public var normalized: Double? {
        let low = sourceRatingMin ?? 0
        guard let high = sourceRatingMax, high > low else { return nil }
        return ((rating - low) / (high - low)).asProgression ?? 0
    }

    /// "4.3 of 5" — stated in the source's own terms rather than converted,
    /// because a reader who knows Hardcover expects Hardcover's numbers.
    public var ratingText: String {
        let value = rating.formatted(.number.precision(.fractionLength(0 ... 1)))
        guard let high = sourceRatingMax else { return value }
        return "\(value) of \(high.formatted(.number.precision(.fractionLength(0))))"
    }
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

    /// Spelled out because the app builds one itself: a position the app has
    /// just written is already known locally, and asking the server to read it
    /// back is both a round trip and a chance to read a staler value.
    public init(
        uuid: String? = nil,
        locator: ReadiumLocator,
        timestamp: Double,
        createdAt: FlexibleDate? = nil,
        updatedAt: FlexibleDate? = nil,
    ) {
        self.uuid = uuid
        self.locator = locator
        self.timestamp = timestamp
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
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
    public var identifiers: [Identifier]
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
    public var identifiers: [Identifier]
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
    public var identifiers: [Identifier]
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

public extension Book {
    /// How long the book's narration runs, in seconds, where it has any.
    ///
    /// The read-along's length first, then the audiobook's: the read-along is
    /// what the reader hears in the app, and the detail badge leads with it
    /// too. Five sites used to spell this chain out inline, two of them the
    /// other way round, so the library sort, the widget and CarPlay could
    /// disagree about the length of one book.
    var narrationDuration: Double? {
        readaloud?.duration ?? audiobook?.duration
    }
}
