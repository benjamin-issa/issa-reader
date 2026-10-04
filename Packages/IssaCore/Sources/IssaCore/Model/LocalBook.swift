import Foundation

/// What makes a `Book` one the reader added from their own files.
///
/// Carried on the book itself (`Book.localCopy`) and stored with it in the
/// device store, so everything the list and Book info show about the copy
/// survives a relaunch without a second table. A server never sends this:
/// `LibraryService` strips it from every book it decodes.
public struct LocalCopy: Codable, Hashable, Sendable {
    /// The name the file had where the reader chose it, for Book info and
    /// for "Choose emma.epub again".
    public var fileName: String
    /// SHA-256 of the EPUB's bytes, lowercase hex. Matches a second import of
    /// the same file, and a file added again after a restore.
    public var fingerprint: String
    /// The size of the copy, in bytes.
    public var byteCount: Int64
    public var importedAt: Date
    /// When the reader last opened it; the list is ordered by this.
    public var lastOpenedAt: Date?
    /// Whether a `cover.jpg` was cut from the book at import.
    public var hasCover: Bool
    /// The package's unique identifier, which matches a book whose bytes have
    /// changed — a fresh download of the same edition — before the hash would.
    public var packageIdentifier: String?
    /// The package version the book declares: "2.0", "3.0".
    public var epubVersion: String?
    /// Laid out as fixed pages, which this reader shows as flowing text.
    public var isFixedLayout: Bool
    /// The notices still owed to the reader, as raw values.
    ///
    /// Strings rather than `[LocalNotice]`: a notice a later build adds must
    /// not make this build fail to decode the whole book — and with it the
    /// reader's place and the row itself. Unknown values are kept and ignored.
    public var noticeValues: [String]

    public init(
        fileName: String,
        fingerprint: String,
        byteCount: Int64,
        importedAt: Date,
        lastOpenedAt: Date? = nil,
        hasCover: Bool = false,
        packageIdentifier: String? = nil,
        epubVersion: String? = nil,
        isFixedLayout: Bool = false,
        notices: [LocalNotice] = [],
    ) {
        self.fileName = fileName
        self.fingerprint = fingerprint
        self.byteCount = byteCount
        self.importedAt = importedAt
        self.lastOpenedAt = lastOpenedAt
        self.hasCover = hasCover
        self.packageIdentifier = packageIdentifier
        self.epubVersion = epubVersion
        self.isFixedLayout = isFixedLayout
        noticeValues = notices.map(\.rawValue)
    }

    /// The notices this build knows how to show, in the order they were raised.
    public var notices: [LocalNotice] {
        get { noticeValues.compactMap(LocalNotice.init(rawValue:)) }
        set {
            // Keeps whatever this build cannot read, so a newer build's notice
            // outlives a round trip through this one.
            let unknown = noticeValues.filter { LocalNotice(rawValue: $0) == nil }
            noticeValues = newValue.map(\.rawValue) + unknown
        }
    }

    /// Whether the book is EPUB 2, which can carry no narration.
    public var isEPUB2: Bool { epubVersion.map { $0.hasPrefix("2") } ?? false }
}

/// Something worth telling the reader once about a book that was added.
///
/// Information only: the book was added and opens normally. Shown on the
/// book's row until the reader dismisses it.
public enum LocalNotice: String, Codable, Hashable, Sendable, CaseIterable {
    /// The book has narration whose audio this device cannot play, so it was
    /// added as text only.
    case narrationUnplayable
    /// The book was designed as fixed pages and is shown as flowing text.
    case fixedLayout
}

/// Where one local book's files live: `Local/<uuid>/`.
///
/// Everything the book creates — the copy, its cover, the narration extracted
/// on first open and the publisher's face — is under this one folder, so
/// removing the book is removing the folder, and nothing that sweeps the
/// server's downloads (`Books/`, `Audio/`, `Fonts/<uuid>/`) can reach it.
public struct LocalBookFiles: Hashable, Sendable {
    public let bookUUID: String
    /// The book's folder.
    public let folder: URL

    /// - Parameter root: the `Local` folder; a test passes a temporary one.
    public init(bookUUID: String, root: URL? = nil) {
        self.bookUUID = bookUUID
        // `safePathComponent`, as every other per-book folder: this one is
        // deleted whole when the book is removed.
        folder = (root ?? Self.defaultRoot)
            .appending(path: bookUUID.safePathComponent, directoryHint: .isDirectory)
    }

    /// `StorageRoot/Local`, excluded from backup by whoever creates it — the
    /// original is still where the reader chose it from.
    public static var defaultRoot: URL { StorageRoot.directory("Local") }

    /// Where copies wait while they are checked, before they have a book.
    public static func incoming(in root: URL? = nil) -> URL {
        (root ?? defaultRoot).appending(path: ".incoming", directoryHint: .isDirectory)
    }

    /// The copy of the EPUB.
    public var epub: URL { folder.appending(path: "book.epub") }
    /// The cover cut from the EPUB at import, at most 1200 px.
    public var cover: URL { folder.appending(path: "cover.jpg") }
    /// The narration, extracted on first open.
    public var narration: URL { folder.appending(path: "Audio", directoryHint: .isDirectory) }
    /// The publisher's face, extracted on open.
    public var fonts: URL { folder.appending(path: "Fonts", directoryHint: .isDirectory) }
}

/// What an EPUB says about itself, in the shape `Book.local` needs.
///
/// Built by `EPUBPackage.localMetadata(fallbackTitle:)`. Kept here rather than
/// in IssaEPUB so the factory below needs nothing but this package.
public struct LocalBookMetadata: Hashable, Sendable {
    public var title: String
    public var subtitle: String?
    public var description: String?
    public var language: String?
    public var publisher: String?
    /// `dc:date` as written.
    public var date: String?
    public var authors: [LocalContributor]
    public var narrators: [LocalContributor]
    /// Everyone else — translators, illustrators, editors — with their role.
    public var creators: [LocalContributor]
    public var series: LocalSeries?
    public var identifier: String?

    public init(
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        language: String? = nil,
        publisher: String? = nil,
        date: String? = nil,
        authors: [LocalContributor] = [],
        narrators: [LocalContributor] = [],
        creators: [LocalContributor] = [],
        series: LocalSeries? = nil,
        identifier: String? = nil,
    ) {
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.language = language
        self.publisher = publisher
        self.date = date
        self.authors = authors
        self.narrators = narrators
        self.creators = creators
        self.series = series
        self.identifier = identifier
    }
}

extension LocalBookMetadata {
    /// `dc:date` as books write it — a timestamp, a day, a month or a bare
    /// year — as the start of the period it names, in UTC.
    static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = StorytellerDate.parse(text) { return date }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts[0].count == 4
        else { return nil }
        let numbers = parts.compactMap { Int($0) }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = numbers[0]
        components.month = numbers.count > 1 ? numbers[1] : 1
        components.day = numbers.count > 2 ? numbers[2] : 1
        guard components.isValidDate else { return nil }
        return components.date
    }
}

public struct LocalContributor: Hashable, Sendable {
    public var name: String
    public var fileAs: String?
    /// The MARC relator code, when the book gave one.
    public var role: String?

    public init(name: String, fileAs: String? = nil, role: String? = nil) {
        self.name = name
        self.fileAs = fileAs
        self.role = role
    }
}

public struct LocalSeries: Hashable, Sendable {
    public var name: String
    public var position: Double?

    public init(name: String, position: Double? = nil) {
        self.name = name
        self.position = position
    }
}

public extension Book {
    /// Whether this book came from the reader's own files rather than a server.
    var isLocal: Bool { localCopy != nil }

    /// The one way to make a `Book` that no server sent.
    ///
    /// There is no public initialiser on purpose — a `Book` is otherwise only
    /// ever decoded — so a book from the reader's files is built here, inside
    /// the package, from what its EPUB says.
    ///
    /// A book with narration the device can play carries a `readaloud` with
    /// status ALIGNED and its length, which is what `hasReadalong`,
    /// `narrationDuration` and the position guard's tolerance read; any other
    /// book carries an `ebook` only. Both name `book.epub`, the copy's name in
    /// its folder. `createdAt` is the import.
    ///
    /// - Parameter uuid: a fresh lowercase uuid per import — never the EPUB's
    ///   own identifier, which two different books can share and which can be
    ///   anything at all.
    static func local(
        uuid: String,
        metadata: LocalBookMetadata,
        narrationDuration: Double?,
        copy: LocalCopy,
    ) -> Book {
        func creators(_ people: [LocalContributor], _ kind: String) -> [Creator] {
            people.enumerated().map { index, person in
                Creator(
                    uuid: "\(uuid)-\(kind)\(index)", name: person.name,
                    fileAs: person.fileAs, role: person.role)
            }
        }
        let filepath = "book.epub"
        let imported = FlexibleDate(copy.importedAt)
        let narrated = narrationDuration.map { $0 > 0 } ?? false
        return Book(
            uuid: uuid,
            title: metadata.title,
            subtitle: metadata.subtitle,
            description: metadata.description,
            language: metadata.language,
            publicationDate: metadata.date.flatMap(LocalBookMetadata.parseDate).map(FlexibleDate.init),
            duration: narrated ? narrationDuration : nil,
            createdAt: imported,
            updatedAt: imported,
            authors: creators(metadata.authors, "a"),
            narrators: creators(metadata.narrators, "n"),
            creators: creators(metadata.creators, "c"),
            series: metadata.series.map { [
                SeriesMembership(uuid: "\(uuid)-s0", name: $0.name, position: $0.position),
            ] } ?? [],
            tags: [],
            collections: [],
            identifiers: [],
            ebook: narrated ? nil : EbookFormat(
                uuid: "\(uuid)-ebook", filepath: filepath,
                isEpub2: copy.isEPUB2, fileSize: Int(clamping: copy.byteCount), identifiers: []),
            readaloud: narrated ? ReadaloudFormat(
                uuid: "\(uuid)-readaloud", filepath: filepath, status: "ALIGNED",
                duration: narrationDuration, fileSize: Int(clamping: copy.byteCount),
                identifiers: []) : nil,
            localCopy: copy,
        )
    }
}
