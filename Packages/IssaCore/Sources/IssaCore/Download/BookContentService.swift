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
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.cacheDirectory = caches.appending(path: "Books", directoryHint: .isDirectory)
        }
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
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

        let data = try await client.getData(
            Endpoint.files(book.uuid),
            query: [URLQueryItem(name: "format", value: format.rawValue)],
        )
        guard !data.isEmpty else { throw StorytellerError.notFound }
        try data.write(to: destination, options: .atomic)
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
