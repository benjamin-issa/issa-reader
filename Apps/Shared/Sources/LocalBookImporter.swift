import CryptoKit
import Foundation
import ImageIO
import IssaCore
import IssaEPUB
import IssaPlayback
import UniformTypeIdentifiers

/// Turns a file the reader chose into a checked copy, ready to be added.
///
/// Off the main actor, every step of it: a book is up to 4 GB, and a read from
/// iCloud Drive can wait on the network for as long as the provider likes.
/// What it hands back is a copy in `Local/.incoming/` and everything the list
/// needs to know about it. Adding it — the folder, the row, the duplicate
/// check against the library — is `LocalLibrary`'s, on the main actor, so the
/// library is only ever changed in one place.
///
/// In the copy deck's order: is it a file, is it an EPUB, is it within 4 GB, is
/// there room; then the copy, made through a file coordinator so a placeholder
/// is downloaded first; then the fingerprint, the container, the lock, the
/// chapters and the narration; then the cover. Any failure or cancellation
/// deletes whatever this run wrote.
struct LocalBookImporter: Sendable {
    /// What a successful run hands to the library.
    struct Prepared: Sendable {
        /// The checked copy, in `.incoming/`.
        let copy: URL
        /// The cover cut from it, also in `.incoming/`, when it had one.
        let cover: URL?
        let fileName: String
        let fingerprint: String
        let byteCount: Int64
        let metadata: LocalBookMetadata
        /// The narration's length when the book narrates here; nil when it has
        /// none, or has narration this device cannot play.
        let narrationDuration: Double?
        let notices: [LocalNotice]
        let packageIdentifier: String?
        let epubVersion: String?
        let isFixedLayout: Bool

        /// Deletes the files this run left in `.incoming/`.
        func discard() {
            try? FileManager.default.removeItem(at: copy)
            if let cover { try? FileManager.default.removeItem(at: cover) }
        }
    }

    /// The local library's root, `Local/`.
    let root: URL
    /// The largest book that can be added: 4 GiB, the most a ZIP entry without
    /// zip64 sizes can be, and more than any EPUB a reader is likely to own.
    var maximumSize: Int64 = 4 * 1024 * 1024 * 1024
    /// Room left over after the copy and its narration, so adding a book never
    /// fills the disk to the last byte.
    var spaceMargin: Int64 = 64 * 1024 * 1024
    /// How much room the volume has. Injectable so a test can be short of it.
    var availableSpace: @Sendable (URL) -> Int64? = { DiskSpace.available(at: $0) }
    /// A cover larger than this is not cut: a 32 MB image is not a cover.
    var maximumCoverBytes = 32 * 1024 * 1024
    /// The longest side of the cover kept, in pixels.
    var coverPixels = 1200
    /// The copy's read size, and how often progress and cancellation are asked.
    var chunkSize = 1 << 20
    /// Whether a same-volume copy may be a clone. A test turns it off to
    /// watch the chunked copy, which is what a book from another volume gets.
    var allowsClone = true
    /// Stands in for a slow copy in a test: called after each chunk, on the
    /// copy's own queue.
    var afterChunk: @Sendable () -> Void = {}

    var incoming: URL { LocalBookFiles.incoming(in: root) }

    /// Runs one file through every check and leaves a copy ready to add.
    ///
    /// - Parameter stage: told as the run moves from downloading to copying to
    ///   checking. Called off the main actor.
    func run(
        _ source: URL, id: UUID,
        stage: @escaping @Sendable (LocalImport.Stage) -> Void,
    ) async throws(LocalImportError) -> Prepared {
        // Balanced on every path, including the thrown ones. A URL that is not
        // security-scoped — one already inside the app's container, as a
        // test's is — answers false and is read on its own permissions.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard scoped || FileManager.default.isReadableFile(atPath: source.path)
            || Self.isUbiquitous(source)
        else { throw .accessDenied }

        let values = try? source.resourceValues(forKeys: [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileSizeKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        // A folder: Apple Books keeps its books unzipped, as a directory that
        // still calls itself .epub, and a picker can be talked into handing one
        // over.
        if values?.isDirectory == true { throw .folder }
        let ext = source.pathExtension.lowercased()
        if ext != "epub", UTType(filenameExtension: ext)?.conforms(to: .epub) != true {
            throw .notAnEPUB(kind: LocalImportError.kind(ofExtension: ext))
        }
        let size = Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
        if size > maximumSize { throw .tooLarge(bytes: size) }
        try checkSpace(needed: size)

        let notDownloaded = values?.isUbiquitousItem == true
            && values?.ubiquitousItemDownloadingStatus != .current
        if notDownloaded { stage(.downloading) }

        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        Self.excludeFromBackup(root)
        let copy = incoming.appending(path: "\(id.uuidString).epub")
        var keepCopy = false
        defer { if !keepCopy { try? FileManager.default.removeItem(at: copy) } }

        let hashed = try await coordinatedCopy(
            from: source, to: copy, expected: size, wasDownloaded: !notDownloaded, stage: stage)
        if Task.isCancelled { throw .copyFailed }

        stage(.checking)
        let byteCount = (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? size
        if byteCount > maximumSize { throw .tooLarge(bytes: byteCount) }
        // The chunked copy hashed every byte as it wrote it; only a clone,
        // which read nothing, is read again for its fingerprint.
        guard let fingerprint = hashed ?? (try? Self.sha256(of: copy, chunkSize: chunkSize))
        else { throw .copyFailed }
        if Task.isCancelled { throw .copyFailed }

        let inspection: EPUBInspection
        do {
            inspection = try EPUBInspection.inspect(copy)
        } catch {
            switch error {
            case .notAnEPUB: throw .notAnEPUB(kind: nil)
            case .damaged: throw .damaged
            case .protected: throw .drmProtected
            }
        }

        // Narration only where every file of it is in the book and plays here;
        // otherwise the book is added as text, and says why.
        var notices: [LocalNotice] = []
        let narrates = AudioPlayability.canNarrate(inspection)
        if !inspection.timeline.isEmpty, !narrates { notices.append(.narrationUnplayable) }
        if inspection.isFixedLayout { notices.append(.fixedLayout) }
        // Extraction on first open roughly duplicates the audio, so it counts.
        if narrates { try checkSpace(needed: Self.adding(byteCount, inspection.audioByteCount)) }
        let duration = narrates
            ? Self.narrationLength(
                declared: inspection.package.metadata.mediaDuration,
                timeline: inspection.timeline.totalDuration)
            : nil

        let cover = incoming.appending(path: "\(id.uuidString).jpg")
        let madeCover = inspection.coverHref.map { cutCover($0, from: inspection.package, to: cover) } ?? false

        keepCopy = true
        let stem = (source.lastPathComponent as NSString).deletingPathExtension
        return Prepared(
            copy: copy,
            cover: madeCover ? cover : nil,
            fileName: source.lastPathComponent,
            fingerprint: fingerprint,
            byteCount: byteCount,
            metadata: inspection.package.localMetadata(fallbackTitle: stem.isEmpty ? "Untitled" : stem),
            narrationDuration: duration,
            notices: notices,
            packageIdentifier: inspection.package.metadata.uniqueIdentifier,
            epubVersion: inspection.version,
            isFixedLayout: inspection.isFixedLayout)
    }

    // MARK: - Narration length

    /// The longest narration a book is taken to have: a thousand hours,
    /// several times the longest audiobook sold.
    static let longestNarration: Double = 1000 * 3600

    /// How long the narration is, for the row, Book info and the player.
    ///
    /// The book's own `media:duration` first, then what its clips add up to
    /// — whichever is a length at all. Both are the file's claims: 1e21
    /// seconds is finite and passes every check the parser makes, and
    /// stored, it trapped the row on every draw (R-01). A claim past
    /// `longestNarration` is passed over for the other; with neither sane,
    /// the narration still plays, so it is clamped rather than dropped —
    /// nil here would add the book as text.
    static func narrationLength(declared: Double?, timeline: Double) -> Double? {
        func sane(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && $0 > 0 && $0 <= longestNarration ? $0 : nil }
        }
        if let length = sane(declared) ?? sane(timeline) { return length }
        let claimed = [declared ?? 0, timeline].contains { $0 > 0 }
        return claimed ? longestNarration : nil
    }

    // MARK: - Room

    private func checkSpace(needed: Int64) throws(LocalImportError) {
        guard let free = availableSpace(root.deletingLastPathComponent()) else { return }
        if free < Self.adding(needed, spaceMargin) { throw .notEnoughSpace(needed: needed, free: free) }
    }

    /// A sum of sizes a file declared, saturating: a trap here is a crash
    /// while the book is being checked, where "not enough space" belonged.
    static func adding(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

    // MARK: - The copy

    /// Copies through a file coordinator, which is what makes iCloud Drive and
    /// other providers fetch a placeholder before it is read.
    ///
    /// The coordinator blocks its thread until the provider delivers — for as
    /// long as the provider likes — so it runs on a queue of its own rather
    /// than tying up a thread the concurrency pool shares, and cancelling the
    /// import cancels it through `NSFileCoordinator.cancel()` and stops the copy
    /// at its next chunk. Same volume: `copyItem`, which APFS makes a clone —
    /// instant, and no extra space while the original exists. Otherwise a
    /// chunked copy that says how far it has got.
    ///
    /// - Returns: the copy's SHA-256 when the chunked copy made it, which
    ///   hashes as it goes; nil for a clone.
    private func coordinatedCopy(
        from source: URL, to destination: URL, expected: Int64, wasDownloaded: Bool,
        stage: @escaping @Sendable (LocalImport.Stage) -> Void,
    ) async throws(LocalImportError) -> String? {
        // Boxed: `NSFileCoordinator` is not `Sendable`, and is used from two
        // places — the queue that reads, and the cancellation handler, whose
        // `cancel()` Foundation documents as safe from any thread.
        let coordinator = CoordinatorBox()
        let cancelled = CancelFlag()
        let chunkSize = chunkSize
        let afterChunk = afterChunk
        let cloneable = allowsClone && Self.sameVolume(source, destination.deletingLastPathComponent())
        let outcome: Result<String?, LocalImportError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var coordinationError: NSError?
                    var result: Result<String?, LocalImportError> = .failure(.copyFailed)
                    // `.withoutChanges`: the file as it is, without asking its
                    // writer to save first, which a book in Files never needs.
                    // Synchronous: the accessor has run by the time this returns.
                    coordinator.value.coordinate(
                        readingItemAt: source, options: [.withoutChanges], error: &coordinationError,
                    ) { readable in
                        stage(.copying(0))
                        result = Self.copy(
                            readable, to: destination, expected: expected, cloneable: cloneable,
                            chunkSize: chunkSize, afterChunk: afterChunk,
                            isCancelled: { cancelled.isSet }, stage: stage)
                    }
                    if coordinationError != nil {
                        // The accessor never ran: the provider could not deliver.
                        result = .failure(wasDownloaded ? .copyFailed : .notDownloaded)
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancelled.set()
            coordinator.value.cancel()
        }
        switch outcome {
        case let .success(hash):
            return hash
        case let .failure(error):
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// The copy itself, inside the coordinator's accessor.
    ///
    /// Progress is told only when the whole percent the row shows moves:
    /// each report is a hop to the main actor that rewrites the list, and a
    /// 4 GB book copied a megabyte at a time made four thousand of them for
    /// a hundred visible changes. The bytes are hashed as they are written,
    /// so the fingerprint costs no second read of the copy.
    ///
    /// - Returns: the copy's SHA-256, or nil for a clone.
    private static func copy(
        _ source: URL, to destination: URL, expected: Int64, cloneable: Bool,
        chunkSize: Int, afterChunk: @Sendable () -> Void, isCancelled: () -> Bool,
        stage: @Sendable (LocalImport.Stage) -> Void,
    ) -> Result<String?, LocalImportError> {
        try? FileManager.default.removeItem(at: destination)
        if cloneable {
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                stage(.copying(1))
                return .success(nil)
            } catch {
                // Fall through to the chunked copy, which reports the reason
                // if this was more than a clone refused.
                try? FileManager.default.removeItem(at: destination)
            }
        }
        guard let input = try? FileHandle(forReadingFrom: source) else {
            return .failure(.accessDenied)
        }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination)
        else { return .failure(.copyFailed) }
        defer { try? output.close() }
        var written: Int64 = 0
        let total = max(expected, 1)
        var hasher = SHA256()
        // `.copying(0)` was told as the accessor began.
        var reportedPercent = 0
        while true {
            if isCancelled() { return .failure(.copyFailed) }
            // `read(upToCount:)` answers nil at the end of the file, not an
            // empty chunk: taken for a failure, it made every copy that was
            // not a clone — a book from a USB drive or a network share —
            // end in "Couldn't copy this book".
            let chunk: Data
            do { chunk = try input.read(upToCount: chunkSize) ?? Data() } catch { return .failure(.copyFailed) }
            if chunk.isEmpty { break }
            do { try output.write(contentsOf: chunk) } catch { return .failure(.copyFailed) }
            hasher.update(data: chunk)
            written += Int64(chunk.count)
            let fraction = min(Double(written) / Double(total), 1)
            let percent = Int((fraction * 100).rounded(.down))
            if percent > reportedPercent {
                reportedPercent = percent
                stage(.copying(fraction))
            }
            afterChunk()
        }
        return .success(Self.hex(hasher.finalize()))
    }

    // MARK: - Fingerprint and cover

    /// SHA-256 of the file, read a megabyte at a time rather than whole.
    static func sha256(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Cuts the cover out of the book as a JPEG of at most `coverPixels`.
    private func cutCover(_ href: String, from package: EPUBPackage, to destination: URL) -> Bool {
        guard let size = package.archive.size(of: href), size <= maximumCoverBytes,
              let data = try? package.archive.read(href),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return false }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: coverPixels,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let output = CGImageDestinationCreateWithURL(
                  destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(
            output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(output)
    }

    // MARK: - Files

    static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    /// Whether two locations are on one volume, so a copy between them can be
    /// a clone.
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let left = try? a.resourceValues(forKeys: key).volumeIdentifier as? NSObject,
              let right = try? b.resourceValues(forKeys: key).volumeIdentifier as? NSObject
        else { return false }
        return left.isEqual(right)
    }

    /// The whole local tree stays out of backups: the original is still where
    /// the reader chose it from, and a second copy in iCloud would cost them
    /// twice the quota for the same book.
    static func excludeFromBackup(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}

/// A cancellation the copy's own queue can see: `Task.isCancelled` cannot be
/// read from a thread no task is running on.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// The file coordinator a copy reads through, shared with the handler that
/// cancels it.
final class CoordinatorBox: @unchecked Sendable {
    let value = NSFileCoordinator()
}
