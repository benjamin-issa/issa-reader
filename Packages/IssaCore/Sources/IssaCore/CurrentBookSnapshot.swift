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

    private static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: filename)
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
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
