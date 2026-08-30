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
    /// Whether the cover beside this snapshot is the square audiobook art.
    ///
    /// The widget has one cover file and no other way to know its shape, so
    /// without this it sized every cover to the portrait aspect — which crops
    /// away a third of a square jacket on the medium family and more than half
    /// on the large one.
    public var coverIsSquare: Bool
    public var updatedAt: Date

    public init(
        bookID: String, title: String, author: String, chapter: String? = nil,
        progress: Double, remaining: TimeInterval? = nil, isPlaying: Bool = false,
        coverIsSquare: Bool = false,
        updatedAt: Date = .now,
    ) {
        self.bookID = bookID
        self.title = title
        self.author = author
        self.chapter = chapter
        self.progress = progress
        self.remaining = remaining
        self.isPlaying = isPlaying
        self.coverIsSquare = coverIsSquare
        self.updatedAt = updatedAt
    }

    /// The line under the title on a small widget: "2h 18m left · Part 3",
    /// dropping whichever half is unknown, and the author when both are.
    ///
    /// The chapter is filtered rather than trusted. `ReaderModel.chapterTitle`
    /// falls back to the book's own title when no navigation entry matches the
    /// spine document — which is every plain EPUB — so an unfiltered chapter
    /// printed the title twice. An empty one is reachable too, from a table of
    /// contents anchor with no text, and left a dangling separator.
    public var subtitle: String {
        var parts: [String] = []
        if let remaining, remaining.isFinite, remaining > 0 {
            parts.append(Self.durationText(remaining) + " left")
        }
        if let chapter {
            let trimmed = chapter.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != title { parts.append(trimmed) }
        }
        return parts.isEmpty ? author : parts.joined(separator: " · ")
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    // Spelled out because the decoder below names them.
    enum CodingKeys: String, CodingKey {
        case bookID, title, author, chapter, progress, remaining, isPlaying
        case coverIsSquare, updatedAt
    }

    /// Decoded field by field, so a snapshot written by an older build still
    /// reads. The widget is a separate process and can be running against a
    /// file the previous version left behind; the synthesised decoder would
    /// fail the whole thing over one absent key and the widget would show its
    /// placeholder instead of the book.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookID = try container.decode(String.self, forKey: .bookID)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        chapter = try container.decodeIfPresent(String.self, forKey: .chapter)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        remaining = try container.decodeIfPresent(TimeInterval.self, forKey: .remaining)
        isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        coverIsSquare = try container.decodeIfPresent(Bool.self, forKey: .coverIsSquare) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
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
