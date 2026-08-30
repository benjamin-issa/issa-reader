import Foundation

/// How the library is arranged on screen.
///
/// Sorting and filtering happen here rather than on the server, because
/// `GET /books` on 2.14.21 takes no parameters at all — the whole catalogue
/// arrives in one response, so every arrangement of it is a local operation.
/// That is a constraint, but it is also why these are instant and work offline.
public struct LibraryArrangement: Codable, Hashable, Sendable {
    public enum Sort: String, Codable, Sendable, CaseIterable, Identifiable {
        case recent
        case title
        case author
        case added
        case progress
        case duration

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .recent: "Recently read"
            case .title: "Title"
            case .author: "Author"
            case .added: "Recently added"
            case .progress: "Progress"
            case .duration: "Length"
            }
        }
    }

    /// A shelf: one of the standard cuts through a library.
    public enum Shelf: String, Codable, Sendable, CaseIterable, Identifiable {
        case all
        case reading
        case toRead
        case finished
        case downloaded
        case withNarration

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .all: "All books"
            case .reading: "Reading"
            case .toRead: "To read"
            case .finished: "Finished"
            case .downloaded: "Downloaded"
            case .withNarration: "With narration"
            }
        }
    }

    public var sort: Sort
    public var ascending: Bool
    public var shelf: Shelf
    /// Tag names to require. Empty means no tag filter at all.
    public var tags: Set<String>

    public init(
        sort: Sort = .recent, ascending: Bool = false,
        shelf: Shelf = .all, tags: Set<String> = [],
    ) {
        self.sort = sort
        self.ascending = ascending
        self.shelf = shelf
        self.tags = tags
    }

    /// True when anything other than the default arrangement is in force, so
    /// the UI can say so rather than leaving a filtered library looking short.
    public var isFiltering: Bool { shelf != .all || !tags.isEmpty }
}

public extension LibraryArrangement {
    /// The arrangement the reader last chose, or the default.
    ///
    /// Reading it here rather than in the app model keeps the key and the shape
    /// in one place — the two have to agree, and they drift when they are apart.
    static func restored(from defaults: UserDefaults = .standard) -> LibraryArrangement {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(LibraryArrangement.self, from: data)
        else { return LibraryArrangement() }
        return value
    }

    func store(in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static var storageKey: String { "issa.library.arrangement" }

    /// Applies the arrangement. `isDownloaded` is injected because whether a
    /// book is on disk is the app's business, not the model's.
    func apply(to books: [Book], isDownloaded: (Book) -> Bool = { _ in false }) -> [Book] {
        var filtered = books.filter { book in
            switch shelf {
            case .all: true
            case .reading: Self.stage(of: book) == .reading
            case .toRead: Self.stage(of: book) == .toRead
            case .finished: Self.stage(of: book) == .finished
            case .downloaded: isDownloaded(book)
            case .withNarration: book.hasReadalong || book.audiobook != nil
            }
        }
        if !tags.isEmpty {
            // Every selected tag must be present: narrowing, not widening, which
            // is what a reader means by picking a second tag.
            filtered = filtered.filter { book in
                tags.isSubset(of: Set(book.tags.map(\.name)))
            }
        }
        return sorted(filtered)
    }

    enum Stage: Sendable { case toRead, reading, finished }

    /// Which of the three reading stages a book is in.
    ///
    /// Status names belong to the server and an admin may rename them, so this
    /// reads the name rather than matching a fixed vocabulary. Order matters:
    /// "Currently Reading" contains "read", so testing for finished first would
    /// file every book in progress as done.
    static func stage(of book: Book) -> Stage {
        guard let name = book.status?.name.lowercased(), !name.isEmpty else { return .toRead }
        if name.contains("reading") || name.contains("in progress") { return .reading }
        if name.contains("to read") || name.contains("unread")
            || name.contains("want") || name.contains("not started") { return .toRead }
        if name.contains("read") || name.contains("finished") || name.contains("done") {
            return .finished
        }
        // An entirely custom status ("Abandoned", "Reference") is not one of
        // the three; treating it as unstarted is the least wrong answer.
        return .toRead
    }

    private func sorted(_ books: [Book]) -> [Book] {
        let ordered: [Book]
        switch sort {
        case .recent:
            // Books never opened have no position and belong at the end
            // whichever way the sort runs, not interleaved with recent reads.
            ordered = books.sorted { left, right in
                let l = left.position?.timestamp ?? -.greatestFiniteMagnitude
                let r = right.position?.timestamp ?? -.greatestFiniteMagnitude
                return l > r
            }
        case .title:
            ordered = books.sorted { Self.sortKey($0.title) < Self.sortKey($1.title) }
        case .author:
            ordered = books.sorted {
                let l = $0.authors.first?.fileAs ?? $0.byline
                let r = $1.authors.first?.fileAs ?? $1.byline
                return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
            }
        case .added:
            ordered = books.sorted {
                ($0.createdAt?.value ?? .distantPast) > ($1.createdAt?.value ?? .distantPast)
            }
        case .progress:
            ordered = books.sorted { ($0.progress ?? 0) > ($1.progress ?? 0) }
        case .duration:
            ordered = books.sorted { Self.duration(of: $0) > Self.duration(of: $1) }
        }
        return ascending ? ordered.reversed() : ordered
    }

    static func duration(of book: Book) -> Double {
        book.readaloud?.duration ?? book.audiobook?.duration ?? 0
    }

    /// Sorting titles the way a shelf does: leading articles ignored, so
    /// *The Time Machine* files under T for Time.
    static func sortKey(_ title: String) -> String {
        let lowered = title.lowercased()
        for article in ["the ", "a ", "an "] where lowered.hasPrefix(article) {
            return String(lowered.dropFirst(article.count))
        }
        return lowered
    }
}
