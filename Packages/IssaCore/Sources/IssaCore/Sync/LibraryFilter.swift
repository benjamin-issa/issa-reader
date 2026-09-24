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
        case narrator
        case series

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .recent: "Recently read"
            case .title: "Title"
            case .author: "Author"
            case .added: "Recently added"
            case .progress: "Progress"
            case .duration: "Length"
            case .narrator: "Narrator"
            case .series: "Series"
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
            case .withNarration: "With audio"
            }
        }
    }

    public var sort: Sort
    public var ascending: Bool
    public var shelf: Shelf
    /// Tag names to require. Empty means no tag filter at all.
    public var tags: Set<String>

    /// `.added` rather than `.recent`: resuming a book left this screen for
    /// the Reading tab, and a browse surface ordered by what you last
    /// resumed was ordered by nothing a browser cares about.
    public init(
        sort: Sort = .added, ascending: Bool = false,
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

    // Spelled out rather than synthesised, because the decoder below names them.
    enum CodingKeys: String, CodingKey {
        case sort, ascending, shelf, tags
    }

    /// Decoded field by field, with a default for anything absent or unknown.
    ///
    /// The synthesised decoder fails the *whole* blob when one value is not
    /// recognised, and `restored(from:)` falls back to a fresh arrangement on
    /// failure — so adding a `Sort` case, or reading a blob written by a newer
    /// build, would silently reset a reader's shelf, tags and direction along
    /// with the sort. One unfamiliar value should cost one field.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = LibraryArrangement()
        sort = Self.decodeCase(Sort.self, from: container, key: .sort) ?? fallback.sort
        shelf = Self.decodeCase(Shelf.self, from: container, key: .shelf) ?? fallback.shelf
        ascending = try container.decodeIfPresent(Bool.self, forKey: .ascending) ?? fallback.ascending
        tags = try container.decodeIfPresent(Set<String>.self, forKey: .tags) ?? fallback.tags
    }

    /// Reads a string-backed case, treating an unrecognised one as absent.
    ///
    /// `decodeIfPresent` still throws when the key is there but the value is
    /// not a known case, which is exactly the newer-build blob this guards.
    private static func decodeCase<T: RawRepresentable & Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
    ) -> T? where T.RawValue == String {
        // `try?` flattens the doubly-optional decodeIfPresent result.
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return T(rawValue: raw)
    }
}

public extension LibraryArrangement {
    /// The arrangement the reader last chose, or the default.
    ///
    /// Reading it here rather than in the app model keeps the key and the shape
    /// in one place — the two have to agree, and they drift when they are apart.
    static func restored(from defaults: UserDefaults = .standard) -> LibraryArrangement {
        // The default used to be "Recently read", and every reader who never
        // opened the sort menu has that stored. Flip it to the new default
        // once; a reader who picks "Recently read" after this keeps it. A
        // reader who chose it *before* this build loses it this one time —
        // a stored `.recent` cannot say whether it was chosen or inherited.
        // The flag is set on every path, including a fresh install with no
        // blob yet, so a later deliberate choice is never mistaken for the
        // inherited one.
        let migrate = !defaults.bool(forKey: sortMigrationKey)
        defer { defaults.set(true, forKey: sortMigrationKey) }
        guard let data = defaults.data(forKey: storageKey),
              var value = try? JSONDecoder().decode(LibraryArrangement.self, from: data)
        else { return LibraryArrangement() }
        if migrate, value.sort == .recent {
            value.sort = LibraryArrangement().sort
            value.store(in: defaults)
        }
        return value
    }

    func store(in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static var storageKey: String { "issa.library.arrangement" }
    static var sortMigrationKey: String { "issa.library.arrangement.sortMigrated" }

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
    /// This matches the status name loosely rather than against a fixed
    /// vocabulary. 2.14.21 ships exactly the three built-ins, with no API to
    /// add or rename one, so there the looseness is only defensive; 3.x lets an
    /// admin add statuses of their own, which it files by their wording where
    /// that says a stage. Order matters: "Currently Reading" contains "read",
    /// so testing for finished first would file every book in progress as
    /// done. It reads `name`, never `label`: 3.x fixes the built-in names and
    /// puts an admin's wording in the label, so "Read" relabelled "Finished" is
    /// still named "Read".
    ///
    /// A book with *no* status is filed by its progress, with the server's own
    /// thresholds: at 98% or more it is finished, past the start it is being
    /// read, otherwise it is unstarted. 2.x never sends one without a status:
    /// it gives every book a status row for every reader — adding a book
    /// writes one per user, adding a user one per book, and a migration
    /// backfilled any gap. 3.x does send one, and never moves it — its
    /// position write updates a status row the book does not have — so a book
    /// read to the end in the web reader would otherwise sit on "To read"
    /// forever. This files it where 2.x would have. Display only: nothing is
    /// written back; `StatusAdvance` does that for positions this device
    /// writes.
    static func stage(of book: Book) -> Stage {
        guard let status = book.status else {
            let progress = book.progress ?? 0
            if progress >= StatusAdvance.finishedThreshold { return .finished }
            return progress > 0 ? .reading : .toRead
        }
        let name = status.name.lowercased()
        guard !name.isEmpty else { return .toRead }
        // Whole words for the short ones, substrings only for the phrases.
        // "Abandoned" contains "done", so a reader who abandoned a book found
        // it filed under Finished.
        let words = Set(name.split { !$0.isLetter }.map(String.init))
        if words.contains("reading") || name.contains("in progress") { return .reading }
        if name.contains("to read") || words.contains("unread")
            || words.contains("want") || name.contains("not started") { return .toRead }
        if words.contains("read") || words.contains("finished") || words.contains("done") {
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
            // whichever way the sort runs, not interleaved with recent reads —
            // so the direction lives in the comparator, where it flips only
            // the timestamps. The blanket reversal below would flip the
            // never-opened block to the top of the shelf.
            return books.sorted { left, right in
                switch (left.position?.timestamp, right.position?.timestamp) {
                case let (l?, r?): ascending ? l < r : l > r
                case (nil, _?): false
                case (_?, nil): true
                case (nil, nil): false
                }
            }
        case .title:
            // The same locale-aware comparison `.author` uses: `String.<` is
            // a code-unit comparison, which files every accented initial
            // after Z — Émile ended up behind Zorro.
            ordered = books.sorted {
                Self.sortKey($0.title)
                    .localizedCaseInsensitiveCompare(Self.sortKey($1.title)) == .orderedAscending
            }
        case .author:
            ordered = books.sorted {
                let l = $0.authors.first?.fileAs ?? $0.byline
                let r = $1.authors.first?.fileAs ?? $1.byline
                return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
            }
        case .added:
            // Books the server never dated go last either way, the rule
            // `.recent` and `.narrator` follow: this is the default sort now,
            // and the blanket reversal below would have put every undated
            // book ahead of the newest arrival.
            return books.sorted { left, right in
                switch (left.createdAt?.value, right.createdAt?.value) {
                case let (l?, r?): ascending ? l < r : l > r
                case (nil, _?): false
                case (_?, nil): true
                case (nil, nil): false
                }
            }
        case .progress:
            ordered = books.sorted { ($0.progress ?? 0) > ($1.progress ?? 0) }
        case .duration:
            ordered = books.sorted { Self.duration(of: $0) > Self.duration(of: $1) }
        case .narrator:
            // Books with no narrator sort last either way, the same rule
            // `.recent` uses for books never opened — and, like `.recent`,
            // the direction lives in the comparator so the reversal below
            // cannot move that bucket to the front.
            return books.sorted {
                let l = $0.narrators.first.map { $0.fileAs ?? $0.name }
                let r = $1.narrators.first.map { $0.fileAs ?? $0.name }
                switch (l, r) {
                case let (l?, r?):
                    return l.localizedCaseInsensitiveCompare(r)
                        == (ascending ? .orderedDescending : .orderedAscending)
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return false
                }
            }
        case .series:
            // Standalone books sort after every series either way, the rule
            // `.recent` and `.narrator` follow for the bucket that has nothing
            // to compare — so the direction lives in the comparator, and the
            // blanket reversal below cannot lift a library's unseried majority
            // above the sequences this sort exists to show.
            return books.sorted { Self.inSeriesOrder($0, $1, ascending: ascending) }
        }
        return ascending ? ordered.reversed() : ordered
    }

    /// Reading order across a whole shelf: series first, each in its own order,
    /// standalone books after them.
    ///
    /// Its own function because the rule is three comparisons deep — series
    /// name, then position within it, then title — and each has to flip with
    /// the direction while the two buckets that carry no value at all, an
    /// unnumbered book and an unseried one, stay where they are.
    static func inSeriesOrder(_ left: Book, _ right: Book, ascending: Bool) -> Bool {
        // The same spelling `.narrator` uses: a comparison that reads forward
        // is `.orderedAscending` unless the reader asked for the reverse.
        let forward: ComparisonResult = ascending ? .orderedDescending : .orderedAscending
        switch (left.primarySeries, right.primarySeries) {
        case let (l?, r?):
            let byName = l.name.localizedCaseInsensitiveCompare(r.name)
            if byName != .orderedSame { return byName == forward }
            switch (l.position, r.position) {
            case let (lp?, rp?) where lp != rp: return ascending ? lp > rp : lp < rp
            // A book the server never numbered has no place in the run, so it
            // sits after the numbered ones whichever way the series is read.
            case (nil, _?): return false
            case (_?, nil): return true
            // Same series, same position, or neither numbered: the title
            // decides, below.
            default: break
            }
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): break
        }
        return sortKey(left.title)
            .localizedCaseInsensitiveCompare(sortKey(right.title)) == forward
    }

    static func duration(of book: Book) -> Double {
        book.narrationDuration ?? 0
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
