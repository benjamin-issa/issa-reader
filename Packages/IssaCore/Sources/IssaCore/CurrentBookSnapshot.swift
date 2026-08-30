import Foundation

/// The small record the app writes and the widget reads.
///
/// Deliberately a plain file in the shared App Group container rather than the
/// library database. A widget extension is held to roughly 30 MB and must not
/// open a SQLite connection that a background download task may be writing to;
/// reading one small JSON file is bounded, predictable work.
public struct CurrentBookSnapshot: Codable, Sendable, Hashable {
    public var bookID: String
    public var title: String
    public var author: String
    public var chapter: String?
    /// 0...1 through the whole book.
    public var progress: Double
    /// Seconds of narration left, when the book has audio.
    public var remaining: TimeInterval?
    public var isPlaying: Bool
    public var updatedAt: Date

    public init(
        bookID: String, title: String, author: String, chapter: String? = nil,
        progress: Double, remaining: TimeInterval? = nil, isPlaying: Bool = false,
        updatedAt: Date = .now,
    ) {
        self.bookID = bookID
        self.title = title
        self.author = author
        self.chapter = chapter
        self.progress = progress
        self.remaining = remaining
        self.isPlaying = isPlaying
        self.updatedAt = updatedAt
    }
}

public enum CurrentBookSnapshotStore {
    /// Must match the App Group in every target's entitlements.
    public static let appGroup = "group.com.benjaminissa.issareader"
    private static let filename = "current-book.json"
    private static let coverFilename = "current-cover.jpg"

    private static func containerURL(_ name: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: name)
    }

    private static var url: URL? { containerURL(filename) }
    /// Where the app leaves a small cover for the widget to draw.
    ///
    /// A file rather than bytes inside the snapshot: JSON with a base64 image
    /// in it would be re-read and re-decoded on every timeline request, and the
    /// widget's memory ceiling is the scarce resource here.
    public static var coverURL: URL? { containerURL(coverFilename) }

    public static func writeCover(_ data: Data) {
        guard let coverURL else { return }
        try? data.write(to: coverURL, options: .atomic)
    }

    public static func readCover() -> Data? {
        guard let coverURL else { return nil }
        return try? Data(contentsOf: coverURL)
    }

    public static func write(_ snapshot: CurrentBookSnapshot) {
        guard let url, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func read() -> CurrentBookSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CurrentBookSnapshot.self, from: data)
    }

    public static func clear() {
        if let url { try? FileManager.default.removeItem(at: url) }
        if let coverURL { try? FileManager.default.removeItem(at: coverURL) }
    }

    /// The URL that opens a book from a widget, a Spotlight result or Handoff.
    ///
    /// A custom scheme rather than a universal link: this app talks to whatever
    /// server its owner runs, so there is no domain to associate with.
    public static func deepLink(bookID: String) -> URL? {
        URL(string: "issareader://book/\(bookID)")
    }
}
