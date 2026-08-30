import Foundation
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

        var result: [String: URL] = [:]
        // One entry per distinct file; a book has a handful of tracks but tens
        // of thousands of entries.
        let hrefs = Set(timeline.entries.map(\.audioHref))

        for href in hrefs {
            let destination = base.appending(path: (href as NSString).lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                let data = try package.archive.read(href)
                try data.write(to: destination, options: .atomic)
            }
            result[href] = destination
        }
        return result
    }

    public static func defaultDirectory(for bookID: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: "Audio/\(bookID)", directoryHint: .isDirectory)
    }

    public static func removeExtractedAudio(for bookID: String) {
        try? FileManager.default.removeItem(at: defaultDirectory(for: bookID))
    }
}
