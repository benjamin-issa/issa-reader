import Foundation

/// Fetches and caches the actual book files.
///
/// Storyteller can serve a book two ways: as a whole file, or as a Readium Web
/// Publication whose resources are fetched individually. Whole-file download is
/// what the reader wants — it is the only form that works offline, and the
/// readaloud EPUB carries its own audio inside the archive, so one download
/// yields both the text and the narration.
public struct BookContentService: Sendable {
    private let client: APIClient
    private let cacheDirectory: URL

    /// Prepared once per process rather than once per construction.
    ///
    /// This type is built inside view bodies — once per edition row on the book
    /// screen, and on every access of the library's `arrangedBooks` — and the
    /// preparation below is a `createDirectory` plus a resource-value write. At
    /// one per render that is a filesystem write per frame.
    private static let preparedDefaultDirectory: URL = {
        let directory = defaultDirectory()
        prepare(directory)
        return directory
    }()

    private static func prepare(_ directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // Not silent. A `try?` here is how an Apple TV spent every session
            // unable to save a single book while the app said nothing: the
            // failure only surfaced at the end of a download, dressed as a
            // network error.
            IssaLog.failure("prepare download directory", error, ["path": directory.path])
        }
        excludeFromBackup(directory)
    }

    public init(client: APIClient, cacheDirectory: URL? = nil) {
        self.client = client
        if let cacheDirectory {
            // An injected directory is a test's, and a fresh one each time, so
            // it does have to be prepared on the spot.
            self.cacheDirectory = cacheDirectory
            Self.prepare(cacheDirectory)
        } else {
            self.cacheDirectory = Self.preparedDefaultDirectory
        }
    }

    /// Where downloaded books live.
    ///
    /// Under `StorageRoot` — Application Support on the phone and the Mac,
    /// Caches on the Apple TV, for the reasons written there. Marked as
    /// excluded from backup either way: these are re-downloadable, and a
    /// library of readaloud editions would otherwise bloat every iCloud backup
    /// by gigabytes.
    public static func defaultDirectory() -> URL {
        StorageRoot.directory("Books")
    }

    static func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    /// Moves anything left in the old Caches location.
    ///
    /// Early builds wrote here; without this, an existing install silently loses
    /// every download it already had.
    ///
    /// Never on tvOS, where Caches *is* the storage root: source and
    /// destination would be the same folder, every file would be skipped as
    /// already present, and the `removeItem` at the end would then delete the
    /// whole library on every launch. The equality guard below says the same
    /// thing without naming a platform; the compile-time return is there so
    /// the intent is impossible to miss.
    public static func migrateFromCachesIfNeeded() {
        #if os(tvOS)
        return
        #else
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Books", directoryHint: .isDirectory)
        migrate(from: caches, to: defaultDirectory())
        #endif
    }

    /// The move itself, separated so it can be tested with two real directories
    /// — including the case where they are the same one.
    static func migrate(from caches: URL, to destination: URL) {
        guard FileManager.default.fileExists(atPath: caches.path) else { return }
        guard caches.standardizedFileURL != destination.standardizedFileURL else { return }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [] {
            let target = destination.appending(path: file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.moveItem(at: file, to: target)
            }
        }
        try? FileManager.default.removeItem(at: caches)
        excludeFromBackup(destination)
    }

    /// Which file to ask the server for. `readaloud` is the aligned EPUB with
    /// embedded audio and SMIL overlays; `ebook` is the plain text-only EPUB.
    public enum Format: String, Sendable, CaseIterable {
        case ebook
        case audiobook
        case readaloud

        /// The reader-facing name for an edition. "Read-along", never the
        /// server's "Readaloud" (item 03); the other two already read plainly.
        ///
        /// Here rather than on a screen because four now say it — the book
        /// detail's editions card, the Downloads screen's rows, its transfer
        /// status line and the Reading tab's section — and the two on the
        /// Downloads screen were still printing `rawValue.capitalized`, so the
        /// app called the same edition "Read-along" in one place and
        /// "Readaloud" in another.
        public var displayName: String {
            switch self {
            case .ebook: "Ebook"
            case .audiobook: "Audiobook"
            case .readaloud: "Read-along"
            }
        }

        /// Whether this edition is a source of the book's text.
        ///
        /// The publisher's face and the question index are derived from text,
        /// and both the ebook and the read-along carry it. An audiobook does
        /// not — so a book left with only an audiobook has no text on the
        /// device, and neither of those derived files has anything behind it.
        public var carriesText: Bool { self != .audiobook }
    }

    public func localURL(for book: Book, format: Format) -> URL {
        Self.localURL(in: cacheDirectory, bookUUID: book.uuid, format: format)
    }

    /// The one place a book's file is named.
    ///
    /// `AppModel` built this same string a second time for the download
    /// manager's destination, so the rule lived in two places and only one
    /// could be fixed.
    ///
    /// The identifier is checked before it names anything.
    /// `URL.appending(path:)` neither encodes nor collapses `../` — verified by
    /// running it — so an unvalidated uuid let a hostile or compromised server
    /// choose the path a downloaded file was written to, and the bytes as well.
    /// A malformed one is hashed rather than stripped, which is the rule
    /// `LibraryStore.filename(for:)` already states for server-supplied keys:
    /// "hash it rather than trying to sanitise". Stripping invites the next
    /// encoding that means the same thing; a hash cannot escape a directory,
    /// and it stays stable so the file is still found again afterwards.
    ///
    /// The rule itself is `String.safePathComponent`, shared rather than spelled
    /// here: three other places name a file or a directory after a book, and two
    /// of them had no guard at all.
    public static func localURL(in directory: URL, bookUUID: String, format: Format) -> URL {
        directory.appending(path: "\(bookUUID.safePathComponent)-\(format.rawValue).epub")
    }

    public func isDownloaded(_ book: Book, format: Format) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: book, format: format).path)
    }

    /// Whether any edition of this book that carries text is still on the device.
    ///
    /// The question a removal has to ask before it releases what a download left
    /// behind. The publisher's face and the question index belong to the *book*,
    /// not to the edition just deleted — either the ebook or the read-along
    /// produces them — so removing one of a book's two editions used to destroy
    /// derived data belonging to the edition still sitting on disk. The reader
    /// found out the next time they opened it: the book set in the fallback
    /// face, and the questions it had already been indexed for starting again.
    ///
    /// Two `stat`s at most, and only on the removal path, which is why it asks
    /// the disk rather than a set held in memory: the set is refreshed *after*
    /// the file goes, and answering from it here would answer about the world
    /// one step ago.
    public static func hasDownloadedText(bookUUID: String, in directory: URL? = nil) -> Bool {
        let directory = directory ?? defaultDirectory()
        return Format.allCases.filter(\.carriesText).contains {
            FileManager.default.fileExists(
                atPath: localURL(in: directory, bookUUID: bookUUID, format: $0).path)
        }
    }

    /// The best format available for reading: the aligned edition when the
    /// server has one, otherwise the plain ebook.
    ///
    /// `missing` is honoured here rather than at each call site, because both
    /// bugs it causes are downstream of this one answer: an audiobook-only book
    /// used to offer "Read" and dead-end in the reader, and a book whose ebook
    /// the server had lost returned `.ebook` and 404'd mid-download.
    ///
    /// Static because it is a question about a `Book`, not about the cache —
    /// `ReaderModel` was constructing an entire service, and three filesystem
    /// syscalls with it, just to ask.
    public static func preferredReadingFormat(for book: Book) -> Format? {
        let readaloudUsable = book.readaloud?.filepath != nil && book.readaloud?.missing != true
        let ebookUsable = book.ebook != nil && book.ebook?.missing != true
        if readaloudUsable, book.readaloud?.isAligned == true { return .readaloud }
        if ebookUsable { return .ebook }
        if readaloudUsable { return .readaloud }
        return nil
    }

    public func preferredReadingFormat(for book: Book) -> Format? {
        Self.preferredReadingFormat(for: book)
    }

    /// Every book with at least one file on disk, from a single directory read.
    ///
    /// `isDownloaded` is one `stat` per book per format; asking it for a whole
    /// library — which the download shelf and its count both do — is thousands
    /// of syscalls per render.
    ///
    /// **Throws rather than reporting an empty library.** The read was a `try?`
    /// coalesced to `[]`, and the reconciliation sweep downstream of it reads
    /// "no books on disk" as "every book departed" and irreversibly deletes each
    /// one's question index, extracted narration and publisher font. A directory
    /// this cannot read is not a directory with nothing in it, and the one
    /// moment they are most likely to be confused is the moment the damage is
    /// largest: a permissions fault, a detached volume or a device still
    /// unlocking says nothing about what the reader downloaded.
    ///
    /// A directory that is *absent* is the one failure that really does mean an
    /// empty set — that is what a fresh install and a "sign out and delete my
    /// downloads" both leave behind — so it is answered rather than thrown.
    public static func downloadedBookUUIDs(in directory: URL? = nil) throws -> Set<String> {
        let directory = directory ?? preparedDefaultDirectory
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return Set(names.compactMap(bookUUID(fromFilename:)))
    }

    /// The uuid a download's filename encodes, or nil if it is not one of ours.
    static func bookUUID(fromFilename name: String) -> String? {
        decodeFilename(name)?.bookUUID
    }

    /// The book *and* the edition a download's filename encodes.
    ///
    /// The inverse of `localURL(in:bookUUID:format:)`, and the only other place
    /// allowed to know the shape. The storage screen needs the format as well
    /// as the uuid — a book with two editions on disk is two rows and two
    /// sizes — and reading a directory once to get both beats one `stat` per
    /// book per format.
    ///
    /// **Bare uuids only.** This is the point where a name found on disk becomes
    /// a book id, and everything downstream then treats that id as trustworthy:
    /// the orphan sweep hands it to `AppModel.removeDownload`, which builds
    /// `Fonts/<id>/` and `Audio/<id>/` and deletes them whole. `..-ebook.epub` is
    /// a filename anybody can create — an unzipped archive, a sync client, a
    /// hostile server naming a book — and it decoded to the id `..`, which made
    /// both of those directories the storage root. `safePathComponent` stops the
    /// escape a second time over; this stops it being asked for.
    ///
    /// It also means the inverse is honest. `localURL` writes `unsafe-<hash>`
    /// for a malformed id, and reading that back as though it were the id would
    /// have named a *third* file — so a name this cannot decode is deliberately
    /// no longer one of ours, and the sweep leaves it alone rather than
    /// deleting it under a name it invented.
    static func decodeFilename(_ name: String) -> (bookUUID: String, format: Format)? {
        guard name.hasSuffix(".epub") else { return nil }
        let stem = String(name.dropLast(".epub".count))
        for format in Format.allCases where stem.hasSuffix("-\(format.rawValue)") {
            let uuid = String(stem.dropLast(format.rawValue.count + 1))
            return uuid.isBareUUID ? (uuid, format) : nil
        }
        return nil
    }

    /// Downloads the file if it is not already cached, and returns its location.
    @discardableResult
    public func ensureDownloaded(_ book: Book, format: Format) async throws -> URL {
        let destination = localURL(for: book, format: format)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        // Streamed to a temporary file rather than held in memory: a readaloud
        // edition is hundreds of megabytes, and this path runs on the main
        // reading flow where a memory spike shows up as a jettison.
        try await client.download(
            Endpoint.files(book.uuid),
            query: [URLQueryItem(name: "format", value: format.rawValue)],
            to: destination,
        )
        return destination
    }

    public func removeDownload(_ book: Book, format: Format) {
        Self.removeDownload(bookUUID: book.uuid, format: format, in: cacheDirectory)
    }

    /// Deletes one edition's file without needing a client.
    ///
    /// Removal is a filesystem operation and never was anything else, but the
    /// only spelling of it was an instance method — so `AppModel.removeDownload`
    /// had to build a whole `BookContentService`, and therefore had to be
    /// behind `guard let session`, and therefore did nothing at all once the
    /// reader had signed out keeping their downloads. It also takes a uuid
    /// rather than a `Book`, which is what lets a file whose book has left the
    /// catalogue be deleted at all.
    public static func removeDownload(bookUUID: String, format: Format, in directory: URL? = nil) {
        let directory = directory ?? defaultDirectory()
        try? FileManager.default.removeItem(
            at: localURL(in: directory, bookUUID: bookUUID, format: format))
    }
}
