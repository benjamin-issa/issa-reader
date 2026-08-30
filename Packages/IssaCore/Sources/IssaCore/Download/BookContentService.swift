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

    public init(client: APIClient, cacheDirectory: URL? = nil) {
        self.client = client
        self.cacheDirectory = cacheDirectory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        Self.excludeFromBackup(self.cacheDirectory)
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
    public enum Format: String, Sendable {
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
    public func preferredReadingFormat(for book: Book) -> Format? {
        if book.readaloud?.filepath != nil, book.readaloud?.isAligned == true { return .readaloud }
        if book.ebook != nil { return .ebook }
        if book.readaloud?.filepath != nil { return .readaloud }
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
