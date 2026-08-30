import Foundation

/// The tiny record the app writes and the widget reads.
///
/// Deliberately a plain file in the shared App Group container rather than the
/// library database: the widget process is memory-constrained and must not open
/// a SQLite connection that a background download task may be writing to.
public enum CurrentBookSnapshotStore {
    public static let appGroup = "group.com.benjaminissa.issareader"
    private static let filename = "current-book.json"

    private struct Payload: Codable {
        var title: String
        var author: String
        var progress: Double
        var updatedAt: Date
    }

    private static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: filename)
    }

    public static func write(title: String, author: String, progress: Double) {
        guard let url else { return }
        let payload = Payload(title: title, author: author, progress: progress, updatedAt: .now)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> CurrentBookEntry? {
        guard let url, let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return CurrentBookEntry(
            date: payload.updatedAt,
            title: payload.title,
            author: payload.author,
            progress: payload.progress,
        )
    }
}
