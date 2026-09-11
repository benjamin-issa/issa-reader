import Foundation
import IssaCore
import IssaEPUB

/// Extracts a readaloud EPUB's embedded audio to disk.
///
/// Storyteller's aligner writes the narration inside the EPUB at `Audio/<name>`,
/// so one download yields both text and audio. `AVPlayer` cannot read from
/// inside a ZIP, so the tracks are written out once and cached — which also
/// means playback survives with no network at all.
public enum AudioExtraction {
    /// One extraction at a time, process-wide.
    ///
    /// The reader and the car can now ask for the same book's narration at
    /// once: opening an aligned book extracts it, and `startListening` extracts
    /// it again to build a manifest over the chunks. The body below is
    /// idempotent everywhere except the legacy-name rescue — `moveItem` on a
    /// file the other run has already moved throws, and the throw aborts an
    /// extraction that was otherwise fine, so the book simply refuses to play.
    /// Coarse on purpose: extraction is I/O-bound and rare, and a lock per book
    /// would be a second thing to get right for no measurable gain.
    ///
    /// `removeExtractedAudio` is under it too, and that is the other half of the
    /// same problem. The removal deletes the very directory an extraction is
    /// writing into, and the two racing left it torn: some chunks gone, some
    /// still there, and a manifest built over the survivors. How long a removal
    /// can be made to wait is bounded by the cancellation check below, which is
    /// what makes taking the lock on the main actor tolerable — the extraction
    /// gives up at the next chunk boundary rather than at the end of the book.
    private static let serial = NSLock()

    /// Extracts every audio file the timeline references.
    ///
    /// Returns archive href to on-disk URL. Already-extracted files are reused,
    /// so reopening a book costs nothing.
    ///
    /// - Parameter isCancelled: asked before anything is created and again
    ///   between chunks; a true answer throws `CancellationError`. The lock
    ///   alone is only half a fix — it turns a torn directory into an
    ///   all-or-nothing one, but the losing run still wins, because `extract`
    ///   opens by creating the directory and then writes every chunk into it. So
    ///   a book deleted mid-extraction came straight back, in full, and stayed
    ///   there uncounted by the storage screen and unreachable from the
    ///   interface. A long read-along is a hundred and seventy-six files and
    ///   several hundred megabytes: an extraction revoked at chunk three must
    ///   not write the remaining hundred and seventy-three.
    ///
    ///   The default is honest for every caller in the app. Both of them run
    ///   inside `Task.detached`, and `Task.isCancelled` read from a synchronous
    ///   call reads the task that is running it.
    public static func extractAudio(
        from package: EPUBPackage,
        timeline: SMILTimeline,
        bookID: String,
        into directory: URL? = nil,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
    ) throws -> [String: URL] {
        try serial.withLock {
            try extract(
                from: package, timeline: timeline, bookID: bookID, into: directory,
                isCancelled: isCancelled)
        }
    }

    private static func extract(
        from package: EPUBPackage,
        timeline: SMILTimeline,
        bookID: String,
        into directory: URL?,
        isCancelled: @Sendable () -> Bool,
    ) throws -> [String: URL] {
        let base = directory ?? defaultDirectory(for: bookID)
        // Before the directory exists, not after. This is the line that used to
        // undo a removal: an extraction that had been waiting on the lock woke
        // up and re-made the folder the removal had just deleted.
        guard !isCancelled() else { throw CancellationError() }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var mutable = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)

        var result: [String: URL] = [:]
        // One entry per distinct file; a book has a handful of tracks but tens
        // of thousands of entries.
        let hrefs = Set(timeline.entries.map(\.audioHref))

        // How many hrefs each *old* name stood for. Files were named by
        // `lastPathComponent` until this branch, and changing the scheme with
        // no migration meant every already-extracted narration was extracted
        // again in full while the old files sat beside the new ones for good.
        // An old name claimed by exactly one href is that href's file and is
        // moved into place; one claimed by more than one is the very collision
        // the rename exists for, so it is ambiguous — deleted, and re-extracted.
        var legacyClaims: [String: Int] = [:]
        for href in hrefs { legacyClaims[(href as NSString).lastPathComponent, default: 0] += 1 }

        for href in hrefs {
            // Between chunks, so a revoked extraction stops at the file it is
            // on rather than at the end of the book. Throwing rather than
            // returning what it has: a partial map read as a complete one is a
            // book that plays chapter one and then stops, which is worse than a
            // book that says it could not be prepared.
            guard !isCancelled() else { throw CancellationError() }
            // The whole href, flattened — not `lastPathComponent`, which collides.
            // A book laid out as Audio/ch01/track.mp3, Audio/ch02/track.mp3 —
            // what a CLI-aligned readaloud produces — mapped every chapter onto
            // one file: the first was written, the `fileExists` check below
            // skipped the rest, and each was then pointed at the first one's
            // bytes. Chapter one's narration played under chapter twelve's
            // highlighted text for the whole book, with no error anywhere, and
            // because `hrefs` is a Set the winner was not even stable between
            // launches. Cached across sessions, so it persisted.
            let destination = base.appending(path: Self.filename(for: href))
            let legacyName = (href as NSString).lastPathComponent
            let legacy = base.appending(path: legacyName)
            if !FileManager.default.fileExists(atPath: destination.path),
               legacyName != Self.filename(for: href),
               FileManager.default.fileExists(atPath: legacy.path) {
                if legacyClaims[legacyName] == 1 {
                    try FileManager.default.moveItem(at: legacy, to: destination)
                } else {
                    try? FileManager.default.removeItem(at: legacy)
                }
            }
            if !FileManager.default.fileExists(atPath: destination.path) {
                let data = try package.archive.read(href)
                try data.write(to: destination, options: .atomic)
            }
            result[href] = destination
        }
        return result
    }

    /// Beside the books, under `StorageRoot`, for the same reason they are.
    ///
    /// Through `safePathComponent`, because this names a directory that
    /// `removeExtractedAudio` then deletes whole. The id was interpolated raw,
    /// so a book id of `..` made `Audio/../` — the storage root — and dropping
    /// one book's narration took every download, the catalogue and the logs with
    /// it. Reachable without a hostile server: the orphan sweep decodes book ids
    /// out of filenames it finds on disk, and `..-ebook.epub` is a filename.
    ///
    /// The component is built and appended on its own rather than interpolated
    /// into `"Audio/\(bookID)"`. A single string with a separator already in it
    /// is a path, not a component, and that is the shape that made an unchecked
    /// id look like it was only ever naming one folder.
    ///
    /// `root` is the `Audio` folder itself, and exists so the removal below can
    /// be tested against a temporary directory. It has to be: on a Mac the
    /// storage root is `~/Library/Application Support`, so a test that proved
    /// the traversal by letting it happen would delete the developer's own.
    public static func defaultDirectory(for bookID: String, in root: URL? = nil) -> URL {
        (root ?? StorageRoot.directory("Audio"))
            .appending(path: bookID.safePathComponent, directoryHint: .isDirectory)
    }

    /// A filesystem-safe name that keeps two same-named tracks apart.
    static func filename(for href: String) -> String {
        let normalized = EPUBArchive.normalize(href)
        let flattened = normalized.replacingOccurrences(of: "/", with: "_")
        // Long hrefs would blow the 255-byte component limit, so anything
        // unreasonable is hashed instead — stably, so the file is found again.
        //
        // `normalized`, not `flattened`: the flattening is only how the short
        // name avoids a path separator, while the normalised href is the
        // identity two spellings of one file have to agree on. Through `FNV1a`
        // rather than a loop of its own, because these names are on devices and
        // a second copy of the loop is a second answer about what they are.
        guard flattened.utf8.count <= 200 else {
            let ext = (normalized as NSString).pathExtension
            return "audio-\(FNV1a.hexadecimal(normalized))." + (ext.isEmpty ? "mp3" : ext)
        }
        return flattened
    }

    /// Drops one book's extracted narration when its download goes.
    ///
    /// Named through `defaultDirectory(for:)` and nothing else, so the directory
    /// this deletes is by construction the directory `extractAudio` wrote to.
    /// Deriving the path a second time here is how a write path and a delete
    /// path come to disagree, and one of the two then escapes the root.
    ///
    /// Under the same lock `extractAudio` holds, because the reader and the car
    /// can both be extracting this book's narration at the moment the reader
    /// deletes it. Unlocked, the removal landed in the middle of the write and
    /// left the directory torn — some chunks gone, some still there — and a
    /// manifest was then built over whichever survived. Serialised, one of the
    /// two happens whole; the cancellation check in `extract` is what decides
    /// which, by making the extraction stand down rather than re-make what this
    /// has just deleted.
    public static func removeExtractedAudio(for bookID: String, in root: URL? = nil) {
        serial.withLock {
            try? FileManager.default.removeItem(at: defaultDirectory(for: bookID, in: root))
        }
    }
}
