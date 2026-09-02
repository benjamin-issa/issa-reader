import Foundation

/// What a car is offered, and in what order.
///
/// Kept here rather than in the CarPlay scene delegate because the app targets
/// have no test target at all, and every rule below is one that is wrong in a
/// way you would only find out about while driving: a book with no audio listed
/// as though it could play, a list longer than the head unit will draw, a
/// subtitle that says nothing useful at a glance.
public struct CarPlayCatalogue: Sendable {
    /// The car's tabs.
    ///
    /// Three, deliberately. CarPlay lists are read at a glance at 70mph, and
    /// the useful questions are "what was I in the middle of", "what else is
    /// there", and "what will play without a signal".
    public enum Shelf: String, Sendable, CaseIterable, Hashable {
        case recent
        case library
        case downloaded

        public var title: String {
            switch self {
            case .recent: "Recent"
            case .library: "Library"
            case .downloaded: "Downloaded"
            }
        }

        public var symbol: String {
            switch self {
            case .recent: "clock"
            case .library: "books.vertical"
            case .downloaded: "arrow.down.circle"
            }
        }

        /// Shown when the shelf has nothing in it, because a blank list in a car
        /// is indistinguishable from an app that has crashed.
        public var emptyMessage: String {
            switch self {
            case .recent: "Nothing started yet"
            case .library: "No audiobooks in your library"
            case .downloaded: "No downloads on this phone"
            }
        }
    }

    public struct Entry: Sendable, Hashable {
        public let bookUUID: String
        public let title: String
        /// Author, and how much is left. Not a synopsis — this is read at a
        /// glance, at speed.
        public let subtitle: String
        public let progress: Double?
        /// Whether it will play with no signal, which in a car is the difference
        /// between working and not.
        public let isDownloaded: Bool
    }

    public let books: [Book]
    public let downloadedUUIDs: Set<String>

    public init(books: [Book], downloadedUUIDs: Set<String> = []) {
        self.books = books
        self.downloadedUUIDs = downloadedUUIDs
    }

    /// Books the car could actually play.
    ///
    /// `servableFormats`, not `availableFormats`: the server creates a readaloud
    /// row when alignment is merely requested, so a bare nil check offers books
    /// with no audio behind them. Listing a text-only book in a car is offering
    /// the driver a button that does nothing.
    var playable: [Book] {
        books.filter {
            let formats = $0.servableFormats
            return formats.contains(.audiobook) || formats.contains(.readaloud)
        }
    }

    /// One shelf's items, in the order the car should draw them.
    ///
    /// - Parameter limit: the head unit's maximum, which varies by car and is
    ///   enforced by CarPlay rather than merely advised. Passing it in rather
    ///   than hard-coding one keeps the truncation at the edge that knows.
    public func entries(for shelf: Shelf, limit: Int) -> [Entry] {
        guard limit > 0 else { return [] }
        let selected: [Book] = switch shelf {
        case .recent:
            LibraryDerivation(books: playable).continueReading
        case .library:
            playable.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .downloaded:
            // Natural order is kept inside the other shelves rather than
            // floating downloads to the top of them: a driver looking for the
            // book they were in the middle of should find it where they left
            // it. This shelf is the offline answer instead.
            //
            // Every download, not `.continueReading`: that filter drops any
            // book without progress, and a book downloaded for the drive and
            // never yet opened is precisely what this shelf exists to offer.
            // In-progress books come first, most recently positioned on top;
            // unstarted downloads follow in the library's own order.
            playable.filter { downloadedUUIDs.contains($0.uuid) }
                .sorted { ($0.position?.timestamp ?? 0) > ($1.position?.timestamp ?? 0) }
        }
        return selected.prefix(limit).map(entry)
    }

    func entry(_ book: Book) -> Entry {
        Entry(
            bookUUID: book.uuid,
            title: book.title,
            subtitle: subtitle(for: book),
            progress: book.progress,
            isDownloaded: downloadedUUIDs.contains(book.uuid),
        )
    }

    /// Driving glanceability: author plus time remaining.
    func subtitle(for book: Book) -> String {
        var parts = [book.byline]
        if let duration = book.audiobook?.duration ?? book.readaloud?.duration, duration > 0 {
            let remaining = duration * (1 - min(max(book.progress ?? 0, 0), 1))
            parts.append(Self.durationText(remaining) + " left")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0m" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
