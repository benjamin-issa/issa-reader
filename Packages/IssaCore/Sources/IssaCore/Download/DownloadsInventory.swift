import Foundation

/// What is on this device, grouped the way every downloads surface draws it.
///
/// Deliberately split in two. `make(books:downloaded:sizes:)` is pure — it is
/// *handed* the sizes rather than reading them — so the grouping, the ordering
/// and the arithmetic are testable without a filesystem; `scan` is the thin
/// layer that walks the disk and hands the result to it. Both halves used to
/// live inside `DownloadsView`, a SwiftUI file no test target can reach, which
/// is why the storage bar could be wrong for a whole release and nothing said
/// so.
///
/// No SwiftUI here on purpose: the Reading tab's section, the Downloads screen
/// and the Apple TV's poster row all render this same value, and a redesign of
/// any of them must not be able to change what the numbers mean.
public struct DownloadsInventory: Sendable, Equatable {
    /// One downloaded edition: which book, which format, how big.
    public struct DownloadedItem: Sendable, Equatable, Identifiable {
        public let book: Book
        public let format: BookContentService.Format
        public let bytes: Int64

        /// Book *and* format: one book can have a read-along and a plain ebook
        /// on the device at once, and they are two rows with two sizes and two
        /// delete buttons.
        public var id: String { "\(book.uuid)-\(format.rawValue)" }

        public init(book: Book, format: BookContentService.Format, bytes: Int64) {
            self.book = book
            self.format = format
            self.bytes = bytes
        }
    }

    /// One file in the Books directory, identified the way this app names them.
    public struct FileKey: Sendable, Hashable, Comparable {
        public let bookUUID: String
        public let format: BookContentService.Format

        public init(bookUUID: String, format: BookContentService.Format) {
            self.bookUUID = bookUUID
            self.format = format
        }

        /// Only so a sweep and a test both get the same order out of a
        /// dictionary, which has none.
        public static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.bookUUID, lhs.format.rawValue) < (rhs.bookUUID, rhs.format.rawValue)
        }
    }

    /// The disk figures, before any of them have been matched to a book.
    ///
    /// A struct rather than eight parameters because `make` is the pure
    /// function under test and a test wants to state one field and default the
    /// rest.
    public struct Sizes: Sendable, Equatable {
        /// Every file in the Books directory this app can name, with its size.
        public var files: [FileKey: Int64]
        /// The whole Books directory, including files no book in the catalogue
        /// claims. The difference between this and the rows is
        /// `unaccountedBytes`, and it is the reason this field exists at all.
        public var booksDirectoryBytes: Int64
        /// Narration extracted from a read-along for playback.
        public var extractedAudioBytes: Int64
        /// The cover cache.
        public var coverBytes: Int64
        /// Faces extracted from books — `Fonts/<book-uuid>/` only. Faces the
        /// reader imported sit at the root of `Fonts/` and are theirs, not the
        /// download's, so they are neither counted here nor deleted with one.
        public var publisherFontBytes: Int64
        /// Room left on the volume, or 0 where the platform will not say.
        public var freeBytes: Int64

        public init(
            files: [FileKey: Int64] = [:],
            booksDirectoryBytes: Int64 = 0,
            extractedAudioBytes: Int64 = 0,
            coverBytes: Int64 = 0,
            publisherFontBytes: Int64 = 0,
            freeBytes: Int64 = 0,
        ) {
            self.files = files
            self.booksDirectoryBytes = booksDirectoryBytes
            self.extractedAudioBytes = extractedAudioBytes
            self.coverBytes = coverBytes
            self.publisherFontBytes = publisherFontBytes
            self.freeBytes = freeBytes
        }
    }

    /// How much of the disk `scan` walks.
    public enum Scope: Sendable {
        /// The Books directory alone: one directory read, no recursion. What
        /// the Reading tab's section asks for — it draws four rows and a total
        /// and has no storage bar, so paying for a recursive walk of the
        /// extracted-audio tree and the cover cache on every appearance buys
        /// it nothing.
        case booksOnly
        /// Everything the storage bar reports, recursive walks included.
        case everything
    }

    /// Every downloaded edition, largest first.
    public let items: [DownloadedItem]
    /// Bytes per format, for the storage bar's bands.
    public let byFormat: [BookContentService.Format: Int64]
    /// Bytes in the Books directory that no row above accounts for.
    ///
    /// Almost always a download whose book has left the catalogue. The storage
    /// headline was the whole directory while the bands only summed books
    /// still in the library, so those bytes were in the total, missing from
    /// the bar, and — because they had no row — impossible to delete from the
    /// UI at all. `orphans` is the deletable subset of them.
    public let unaccountedBytes: Int64
    /// The unaccounted files this app can still name, so a sweep has something
    /// to act on. Not every unaccounted byte is here: anything in the
    /// directory that is not one of our filenames counts towards
    /// `unaccountedBytes` and is deliberately left alone.
    public let orphans: [FileKey]
    public let extractedAudioBytes: Int64
    public let coverBytes: Int64
    public let publisherFontBytes: Int64
    public let freeBytes: Int64
    /// The Books directory as a whole — rows plus `unaccountedBytes`.
    public let bookFileBytes: Int64

    public static let empty = DownloadsInventory(
        books: [], downloaded: [], sizes: Sizes())

    /// Everything this app is using, which is what the headline reports.
    public var totalBytes: Int64 {
        bookFileBytes + extractedAudioBytes + coverBytes + publisherFontBytes
    }

    /// The rows' own total — "4 books · 1.4 GB" counts these, not the caches.
    public var itemBytes: Int64 { Self.bytes(of: items) }

    public var isEmpty: Bool { items.isEmpty }

    /// How many distinct books, which is what the reader counts. Two editions
    /// of one book are two rows but one book.
    public var bookCount: Int { Self.bookCount(of: items) }

    /// The same two questions asked of a subset of the rows.
    ///
    /// A screen showing fewer rows than the scan found — one hiding a removal
    /// that is still inside its undo window — has to report the subset, or the
    /// header says five while four are listed. Statics rather than a second
    /// `reduce` at the call site, so "what is a book" is defined once.
    public static func bookCount(of items: [DownloadedItem]) -> Int {
        Set(items.map(\.book.uuid)).count
    }

    public static func bytes(of items: [DownloadedItem]) -> Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - The pure half

    /// Groups a set of files on disk into rows, in one pass and with no I/O.
    ///
    /// - Parameters:
    ///   - books: the catalogue.
    ///   - downloaded: the uuids with at least one file on disk, which the
    ///     download engine already maintains.
    ///   - sizes: what the disk holds, from `scan` or from a test.
    public init(books: [Book], downloaded: Set<String>, sizes: Sizes) {
        var found: [DownloadedItem] = []
        var totals: [BookContentService.Format: Int64] = [:]
        // Bounded by what is actually on the device, not by the library.
        // `isDownloaded` is a `stat` per book per format, so asking it for a
        // whole catalogue is thousands of syscalls; `downloaded` is the set the
        // download engine already keeps, so a library of a thousand books whose
        // owner has kept three costs three dictionary lookups. That bound is
        // load-bearing and is why this loop is shaped the way it is.
        for book in books where downloaded.contains(book.uuid) {
            for format in BookContentService.Format.allCases {
                guard let bytes = sizes.files[FileKey(bookUUID: book.uuid, format: format)]
                else { continue }
                found.append(DownloadedItem(book: book, format: format, bytes: bytes))
                totals[format, default: 0] += bytes
            }
        }

        // Largest first, because the question this screen answers is "what is
        // taking up the room". Title and format break ties so the order is the
        // same on every run — two 0-byte rows shuffling between refreshes is a
        // list that flickers for no reason.
        items = found.sorted {
            ($0.bytes, $1.book.title, $1.format.rawValue)
                > ($1.bytes, $0.book.title, $0.format.rawValue)
        }
        byFormat = totals

        let known = Set(books.map(\.uuid))
        orphans = sizes.files.keys.filter { !known.contains($0.bookUUID) }.sorted()
        bookFileBytes = sizes.booksDirectoryBytes
        // Clamped: the directory total and the per-file sizes are two reads of
        // a directory a background transfer may have written to in between, and
        // a negative "unaccounted" would draw a band going the wrong way.
        unaccountedBytes = max(0, sizes.booksDirectoryBytes - found.reduce(0) { $0 + $1.bytes })
        extractedAudioBytes = sizes.extractedAudioBytes
        coverBytes = sizes.coverBytes
        publisherFontBytes = sizes.publisherFontBytes
        freeBytes = sizes.freeBytes
    }

    /// The same thing spelled as a function, which is how the call sites read.
    public static func make(
        books: [Book], downloaded: Set<String>, sizes: Sizes,
    ) -> DownloadsInventory {
        DownloadsInventory(books: books, downloaded: downloaded, sizes: sizes)
    }

    /// The books that lost their *last* file between two readings of the disk.
    ///
    /// The question a reconciliation sweep has to ask, and the reason it is
    /// asked of the set rather than of the files: a book with a read-along and
    /// an ebook on the device that loses one of them has not departed, and
    /// deleting its question index, its extracted narration and its publisher
    /// font because one of its two editions went would be wrong in a way the
    /// reader would only discover the next time they opened it.
    ///
    /// Set arithmetic with a name, because it is the definition of the
    /// sweep — and a named definition can be tested where a `subtracting` call
    /// buried in a method cannot.
    public static func departed(from previous: Set<String>, to current: Set<String>) -> Set<String> {
        previous.subtracting(current)
    }

    // MARK: - The disk half

    /// Walks the disk and groups what it finds.
    ///
    /// `nonisolated async`, so it does not adopt the caller's executor and
    /// none of it runs on the thread that draws. It was synchronous and on the
    /// main actor, called again on every change to the pending-transfer count —
    /// which is to say repeatedly, while a download is running.
    public static func scan(
        books: [Book],
        downloaded: Set<String>,
        scope: Scope = .everything,
        booksDirectory: URL? = nil,
    ) async -> DownloadsInventory {
        var sizes = Sizes()
        let directory = booksDirectory ?? BookContentService.defaultDirectory()

        // One directory read for both the per-file sizes and the total. The
        // screen used to `stat` each downloaded book *and* read the whole
        // directory again for the headline; the second read already had every
        // size in it. Non-recursive, because downloads are flat files.
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for entry in entries {
            let bytes = Int64((try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            sizes.booksDirectoryBytes += bytes
            guard let named = BookContentService.decodeFilename(entry.lastPathComponent)
            else { continue }
            sizes.files[FileKey(bookUUID: named.bookUUID, format: named.format)] = bytes
        }

        if scope == .everything {
            sizes.extractedAudioBytes = directorySize(StorageRoot.directory("Audio"))
            // Must match `CoverCache.diskDirectory`: Caches, not Application
            // Support. Sizing a Covers folder nothing ever creates reported
            // the cover cache as zero and dropped its band from the legend.
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            sizes.coverBytes = directorySize(caches.appending(path: "Covers", directoryHint: .isDirectory))
            sizes.publisherFontBytes = subdirectorySize(StorageRoot.directory("Fonts"))
            sizes.freeBytes = DiskSpace.available(at: StorageRoot.url) ?? 0
        }

        return DownloadsInventory(books: books, downloaded: downloaded, sizes: sizes)
    }

    /// Recursive, because narration is extracted into a directory per book.
    public static func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// The subdirectories of a directory, and nothing sitting at its root.
    ///
    /// For `Fonts/`, where the two kinds of file are told apart by depth alone:
    /// `Fonts/<book-uuid>/` came out of a download and goes with it, while a
    /// face at the root was imported by the reader and is theirs. Sizing the
    /// whole tree would put their own fonts in a band labelled as a download's.
    public static func subdirectorySize(_ url: URL) -> Int64 {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.reduce(into: Int64(0)) { total, entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return }
            total += directorySize(entry)
        }
    }
}
