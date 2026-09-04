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
    /// Extracts every audio file the timeline references.
    ///
    /// Returns archive href to on-disk URL. Already-extracted files are reused,
    /// so reopening a book costs nothing.
    public static func extractAudio(
        from package: EPUBPackage,
        timeline: SMILTimeline,
        bookID: String,
        into directory: URL? = nil,
    ) throws -> [String: URL] {
        let base = directory ?? defaultDirectory(for: bookID)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var mutable = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)

        var result: [String: URL] = [:]
        // One entry per distinct file; a book has a handful of tracks but tens
        // of thousands of entries.
        let hrefs = Set(timeline.entries.map(\.audioHref))

        for href in hrefs {
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
            if !FileManager.default.fileExists(atPath: destination.path) {
                let data = try package.archive.read(href)
                try data.write(to: destination, options: .atomic)
            }
            result[href] = destination
        }
        return result
    }

    /// Beside the books, under `StorageRoot`, for the same reason they are.
    public static func defaultDirectory(for bookID: String) -> URL {
        StorageRoot.directory("Audio/\(bookID)")
    }

    /// A filesystem-safe name that keeps two same-named tracks apart.
    static func filename(for href: String) -> String {
        let normalized = EPUBArchive.normalize(href)
        let flattened = normalized.replacingOccurrences(of: "/", with: "_")
        // Long hrefs would blow the 255-byte component limit, so anything
        // unreasonable is hashed instead — stably, so the file is found again.
        guard flattened.utf8.count <= 200 else {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in Data(normalized.utf8) {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
            let ext = (normalized as NSString).pathExtension
            return "audio-\(String(hash, radix: 16))." + (ext.isEmpty ? "mp3" : ext)
        }
        return flattened
    }

    public static func removeExtractedAudio(for bookID: String) {
        try? FileManager.default.removeItem(at: defaultDirectory(for: bookID))
    }
}
