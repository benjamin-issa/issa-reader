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
    /// One extraction at a time *per directory* — which is to say per book.
    ///
    /// The reader and the car can ask for the same book's narration at once:
    /// opening an aligned book extracts it, and `startListening` extracts it
    /// again to build a manifest over the chunks. The body below is idempotent
    /// everywhere except the legacy-name rescue — `moveItem` on a file the
    /// other run has already moved throws, and the throw aborts an extraction
    /// that was otherwise fine, so the book simply refuses to play.
    ///
    /// `removeExtractedAudio` takes the same lock, and that is the other half of
    /// the same problem. The removal deletes the very directory an extraction
    /// is writing into, and the two racing left it torn: some chunks gone, some
    /// still there, and a manifest built over the survivors. How long a removal
    /// can be made to wait is bounded by the cancellation check below — the
    /// extraction gives up at the next chunk boundary — and by nothing else.
    ///
    /// Per directory, because this lock was process-wide, and the removal takes
    /// it synchronously on the main actor: removing book Y from Downloads while
    /// book X's narration was being inflated froze the app for the rest of X's
    /// extraction — tens of seconds to minutes for a long book — and the only
    /// cancellations that could cut it short were for X itself. Two books share
    /// no file, so they share no lock.
    ///
    /// Internal so a test can hold it the way an extraction does.
    static let locks = DirectoryLocks()

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
        let base = directory ?? defaultDirectory(for: bookID)
        // One entry per distinct file — a book has a handful of tracks but tens
        // of thousands of entries — in a fixed order, so a revoked extraction
        // stops at the same file every time and a log of one run reads like
        // the next. A `Set`'s order changes from launch to launch.
        let hrefs = Set(timeline.entries.map(\.audioHref)).sorted()
        return try locks.lock(for: base).withLock {
            // Streamed to disk a slice at a time, never read whole. The
            // archive's in-memory read refuses a member that inflates past
            // 256 MB, which lost a book cut into few, long audio files its
            // narration outright, and held every other file whole in memory
            // on its way to the disk.
            try extract(
                hrefs: hrefs, write: { try package.archive.extract($0, to: $1) },
                into: base, isCancelled: isCancelled)
        }
    }

    /// The extraction itself, over a list of archive hrefs and a way to write
    /// one to a file. Internal so a test can state a layout no fixture book
    /// has.
    ///
    /// - Parameter write: puts the member at an href into a file, whole or not
    ///   at all — `EPUBArchive.extract(_:to:)` writes beside the destination
    ///   and renames, so a failure never leaves a truncated file that the
    ///   `fileExists` check below would take for a finished one next time.
    static func extract(
        hrefs: [String],
        write: (String, URL) throws -> Void,
        into base: URL,
        isCancelled: () -> Bool,
    ) throws -> [String: URL] {
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

        // How many hrefs each *old* name stood for. Files were named by
        // `lastPathComponent` until this branch, and changing the scheme with
        // no migration meant every already-extracted narration was extracted
        // again in full while the old files sat beside the new ones for good.
        // An old name claimed by exactly one href is that href's file and is
        // moved into place; one claimed by more than one is the very collision
        // the rename exists for, so it is ambiguous — deleted, and re-extracted.
        var legacyClaims: [String: Int] = [:]
        for href in hrefs { legacyClaims[(href as NSString).lastPathComponent, default: 0] += 1 }

        // The rescue runs over what an *older build* left, so it runs before
        // this run writes anything. Interleaved with the writes, it could not
        // tell an old leftover from a file this run had just extracted: with a
        // root-level `intro.mp3` beside `Audio/intro.mp3`, the old name
        // `intro.mp3` is claimed twice and is also the root-level track's new
        // name, so when that track was written first the nested track's rescue
        // deleted it, and the reader was handed a file that was gone.
        for href in hrefs {
            // The whole href, flattened — not `lastPathComponent`, which
            // collides. A book laid out as Audio/ch01/track.mp3,
            // Audio/ch02/track.mp3 — what a CLI-aligned readaloud produces —
            // mapped every chapter onto one file: the first was written, the
            // `fileExists` check skipped the rest, and each was then pointed at
            // the first one's bytes. Chapter one's narration played under
            // chapter twelve's highlighted text for the whole book, with no
            // error anywhere. Cached across sessions, so it persisted.
            let destination = base.appending(path: Self.filename(for: href))
            let legacyName = (href as NSString).lastPathComponent
            let legacy = base.appending(path: legacyName)
            guard !FileManager.default.fileExists(atPath: destination.path),
                  legacyName != Self.filename(for: href),
                  FileManager.default.fileExists(atPath: legacy.path)
            else { continue }
            if legacyClaims[legacyName] == 1 {
                try FileManager.default.moveItem(at: legacy, to: destination)
            } else {
                try? FileManager.default.removeItem(at: legacy)
            }
        }

        for href in hrefs {
            // Between chunks, so a revoked extraction stops at the file it is
            // on rather than at the end of the book. Throwing rather than
            // returning what it has: a partial map read as a complete one is a
            // book that plays chapter one and then stops, which is worse than a
            // book that says it could not be prepared.
            guard !isCancelled() else { throw CancellationError() }
            let destination = base.appending(path: Self.filename(for: href))
            if !FileManager.default.fileExists(atPath: destination.path) {
                try write(href, destination)
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
        removeExtractedAudio(at: defaultDirectory(for: bookID, in: root))
    }

    /// Drops narration extracted into a directory the caller chose, under the
    /// lock an extraction into that directory holds.
    ///
    /// For a book added from the reader's own files, whose narration is
    /// extracted into its own folder (`LocalBookFiles.narration`) rather than
    /// `Audio/`: removing the book must neither tear an extraction in progress
    /// nor be undone by one finishing — the race `removeExtractedAudio(for:)`
    /// is locked against.
    ///
    /// Never waits for an extraction to finish the member it is writing.
    /// Cancellation is noticed between members, and a member is streamed whole
    /// however large it is — a narration cut into a couple of files of a
    /// gigabyte or more held the main actor here for the rest of one, seconds
    /// of a frozen interface. When an extraction holds the lock, the folder is
    /// renamed aside instead, which is atomic and does not care what is open
    /// inside it, and deleted off the caller's thread. Nothing can be put back:
    /// the extraction creates its folder once, before its first member, and
    /// every later write — the rename that finishes the member in flight, the
    /// next member's file — names a folder that is no longer there and fails,
    /// which ends that extraction. So the outcome is the one the lock gave,
    /// all or nothing, without the wait.
    ///
    /// Aside into the temporary directory rather than beside the folder, so
    /// nothing that measures or sweeps `Audio/` or a book's own folder ever
    /// sees it, and a crash before the deletion runs leaves it to the system's
    /// own clean-up.
    public static func removeExtractedAudio(at directory: URL) {
        removeExtractedAudio(at: directory, asideIn: FileManager.default.temporaryDirectory)
    }

    /// The removal, with where a folder still being written is set aside named
    /// by the caller: a test's own scratch folder, so it can see the set-aside
    /// copy go.
    static func removeExtractedAudio(at directory: URL, asideIn asideRoot: URL) {
        let lock = locks.lock(for: directory)
        if lock.try() {
            defer { lock.unlock() }
            try? FileManager.default.removeItem(at: directory)
            return
        }
        let aside = asideRoot.appending(
            path: "issa-removing-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard rename(directory.path, aside.path) == 0 else {
            // Nothing there to move — the extraction has not made its folder
            // yet, and its own cancellation check, asked before it does, is
            // what stops it — or a rename the file system refused (another
            // volume), which leaves only the wait this used to make.
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            lock.withLock { try? FileManager.default.removeItem(at: directory) }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: aside)
        }
    }
}

/// One lock per extraction directory, made on first use.
///
/// Keyed by the directory rather than the book id because the directory is
/// what the two operations share: `defaultDirectory(for:)` makes the id a
/// single safe path component, so two ids can in principle name one folder,
/// and a caller may pass a directory of its own. Never emptied — an `NSLock`
/// per book the device has ever extracted is nothing.
final class DirectoryLocks: @unchecked Sendable {
    private let guardLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for directory: URL) -> NSLock {
        let key = directory.standardizedFileURL.path
        return guardLock.withLock {
            if let existing = locks[key] { return existing }
            let made = NSLock()
            locks[key] = made
            return made
        }
    }
}
