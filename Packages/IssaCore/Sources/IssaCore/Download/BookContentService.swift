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
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
    /// Application Support, not Caches: iOS purges Caches under storage
    /// pressure, and a reader who downloaded a book for a flight would find it
    /// gone at exactly the moment there is no network to fetch it again. Marked
    /// as excluded from backup all the same — these are re-downloadable, and a
    /// library of readaloud editions would otherwise bloat every iCloud backup
    /// by gigabytes.
    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Books", directoryHint: .isDirectory)
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
    public static func migrateFromCachesIfNeeded() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Books", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: caches.path) else { return }
        let destination = defaultDirectory()
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
    }

    public func localURL(for book: Book, format: Format) -> URL {
        cacheDirectory.appending(path: "\(book.uuid)-\(format.rawValue).epub")
    }

    public func isDownloaded(_ book: Book, format: Format) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: book, format: format).path)
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
    public static func downloadedBookUUIDs(in directory: URL? = nil) -> Set<String> {
        let directory = directory ?? preparedDefaultDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap(bookUUID(fromFilename:)))
    }

    /// The uuid a download's filename encodes, or nil if it is not one of ours.
    static func bookUUID(fromFilename name: String) -> String? {
        guard name.hasSuffix(".epub") else { return nil }
        let stem = String(name.dropLast(".epub".count))
        for format in Format.allCases where stem.hasSuffix("-\(format.rawValue)") {
            let uuid = String(stem.dropLast(format.rawValue.count + 1))
            return uuid.isEmpty ? nil : uuid
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
        try? FileManager.default.removeItem(at: localURL(for: book, format: format))
    }

    /// Total bytes cached, for the Downloads screen.
    public func cacheSize() -> Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey],
        ) else { return 0 }
        return contents.reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
    }
}
