import Foundation
import IssaEPUB

/// The book an index is built from, and the fingerprint that says whether the
/// index on disk still describes it.
///
/// Holds the opened `EPUBPackage` rather than re-opening: the package is a
/// `Sendable` value over an archive that is nothing but a central directory in
/// memory, so passing it between actors costs a retain, and every chapter body
/// is still inflated lazily when it is read. The EPUB is never unzipped to
/// disk; the index is the only derived file.
public struct BookSource: Sendable {
    /// The catalogue uuid, which names the index file.
    public let bookUUID: String
    /// Where the EPUB itself lives, for the fingerprint.
    public let fileURL: URL
    public let package: EPUBPackage

    public init(bookUUID: String, fileURL: URL, package: EPUBPackage) {
        self.bookUUID = bookUUID
        self.fileURL = fileURL
        self.package = package
    }

    /// Opens the EPUB and takes its fingerprint in one step.
    public init(bookUUID: String, fileURL: URL) throws {
        try self.init(
            bookUUID: bookUUID,
            fileURL: fileURL,
            package: EPUBPackage.open(url: fileURL),
        )
    }

    /// BCP-47 tag from the package metadata, used to pre-flight the model's
    /// supported languages before a question is ever sent.
    public var language: String? { package.metadata.language }

    /// The fingerprint of the file as it is right now.
    public var indexKey: IndexKey {
        IndexKey(fileURL: fileURL, spineCount: package.spine.count)
    }
}

// MARK: -

/// What an index on disk was built from, so a stale one is rebuilt rather than
/// silently answering from the wrong book.
///
/// Size and modification date rather than a content hash: an EPUB is hundreds
/// of megabytes in the readaloud edition, and hashing it would cost more than
/// rebuilding the index. The two versions are the part that actually matters —
/// a change to the chunker or to the parser moves every offset in the file, and
/// an offset that has moved puts the spoiler boundary in the wrong place.
public struct IndexKey: Sendable, Hashable, Codable {
    public var fileSize: Int64
    /// Seconds since the epoch, rounded to the second — filesystems do not all
    /// agree below that, and a false mismatch costs a full rebuild.
    public var modified: Int64
    public var spineCount: Int
    /// Bumped whenever chunking or parsing changes what the offsets mean.
    public var parserVersion: Int
    /// Bumped whenever the SQLite schema changes.
    public var schemaVersion: Int

    /// Chunking, parsing and the image rule together. Anything that moves a
    /// character in the rendered string belongs here.
    public static let currentParserVersion = 1
    /// 2 since the `name` table grew `nameKey`: an index built before it pools
    /// two spellings of one character as two people.
    public static let currentSchemaVersion = 2

    public init(
        fileSize: Int64,
        modified: Int64,
        spineCount: Int,
        parserVersion: Int = IndexKey.currentParserVersion,
        schemaVersion: Int = IndexKey.currentSchemaVersion,
    ) {
        self.fileSize = fileSize
        self.modified = modified
        self.spineCount = spineCount
        self.parserVersion = parserVersion
        self.schemaVersion = schemaVersion
    }

    /// Reads the file's size and date through `FileManager`, deliberately.
    ///
    /// `URL.resourceValues(forKeys:)` caches what it read *on the URL value*,
    /// so a `BookSource` built twice from one long-lived URL reports the size
    /// the file had the first time anyone asked — which is exactly the case
    /// this type exists to catch: the book was re-downloaded, every offset in
    /// the index moved, and the fingerprint says nothing has changed.
    public init(fileURL: URL, spineCount: Int) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modified = attributes?[.modificationDate] as? Date
        self.init(
            fileSize: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            modified: Int64(modified?.timeIntervalSince1970 ?? 0),
            spineCount: spineCount,
        )
    }

    /// One row in `meta`, so the whole key is one read and one comparison.
    public var storedValue: String {
        "\(fileSize)|\(modified)|\(spineCount)|\(parserVersion)|\(schemaVersion)"
    }

    public init?(storedValue: String) {
        let parts = storedValue.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 5,
              let fileSize = Int64(parts[0]), let modified = Int64(parts[1]),
              let spineCount = Int(parts[2]), let parserVersion = Int(parts[3]),
              let schemaVersion = Int(parts[4])
        else { return nil }
        self.init(
            fileSize: fileSize, modified: modified, spineCount: spineCount,
            parserVersion: parserVersion, schemaVersion: schemaVersion,
        )
    }
}
