import AVFoundation
import Foundation
import IssaCore

/// How long each of a read-along's narration chunks actually is.
///
/// A media overlay states clip times and nothing else, so the longest clip end
/// in a file is the only length it can offer — and every file runs on a little
/// after its last word. Summed over a hundred and seventy-six chunks those
/// fractions are minutes, and the sum is the book clock a position is written
/// against, so the estimate is not good enough to persist against the server.
/// Asking AVFoundation is exact; it is also a file open per chunk, which is why
/// the answers are cached.
///
/// The cache lives *beside the extracted audio*, in the directory
/// `AudioExtraction` writes to, and is therefore deleted by
/// `removeExtractedAudio` along with the files it describes. Anywhere else and a
/// deleted download would leave durations behind to be matched against the next
/// extraction's files — which, after a re-download with different transcoding
/// settings, would be a book clock built from lengths no file on the device has.
public enum ChunkDurations {
    static let filename = "durations.json"

    /// How many files are measured at once.
    ///
    /// Each measurement opens a file and parses its headers. Unbounded, a book
    /// of a hundred and seventy-six chunks asks the system for a hundred and
    /// seventy-six file handles at once while the listener is waiting for the
    /// first note; six keeps the I/O busy without that.
    static let parallelism = 6

    public static func cacheURL(bookID: String, in root: URL? = nil) -> URL {
        AudioExtraction.defaultDirectory(for: bookID, in: root).appending(path: filename)
    }

    /// What has already been measured, or nothing.
    ///
    /// Every failure is the same answer — an absent file, a truncated write, a
    /// cache from an older shape of this app. The estimate stands in, and the
    /// measurement runs again; there is nothing here that is worth reporting to
    /// a listener or worth refusing to play over.
    public static func load(bookID: String, in root: URL? = nil) -> [String: TimeInterval] {
        guard let data = try? Data(contentsOf: cacheURL(bookID: bookID, in: root)),
              let decoded = try? JSONDecoder().decode([String: TimeInterval].self, from: data)
        else { return [:] }
        return decoded
    }

    public static func save(
        _ durations: [String: TimeInterval], bookID: String, in root: URL? = nil,
    ) throws {
        let url = cacheURL(bookID: bookID, in: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomically, because this is read on the next launch by a path that
        // cannot tell a half-written file from a short book.
        try JSONEncoder().encode(durations).write(to: url, options: .atomic)
    }

    /// Measures whatever is not already known, and returns the merged answer.
    ///
    /// - Parameter cached: what `load` returned. A file already in here is not
    ///   opened again — reopening every chunk on every play is the cost this
    ///   whole type exists to avoid.
    public static func measure(
        _ files: [String: URL], cached: [String: TimeInterval],
    ) async -> [String: TimeInterval] {
        let pending = Array(files.filter { cached[$0.key] == nil })
        guard !pending.isEmpty else { return cached }

        var measured = cached
        await withTaskGroup(of: (String, TimeInterval?).self) { group in
            var next = 0
            while next < pending.count, next < parallelism {
                let item = pending[next]
                group.addTask { (item.key, await duration(of: item.value)) }
                next += 1
            }
            while let (href, seconds) = await group.next() {
                // Skipped rather than stored: a zero or a NaN in here would be
                // cached as this chunk's length and become a stretch of book
                // clock that no seek can land in. The estimate is better than a
                // number that is wrong.
                if let seconds { measured[href] = seconds }
                if next < pending.count {
                    let item = pending[next]
                    group.addTask { (item.key, await duration(of: item.value)) }
                    next += 1
                }
            }
        }
        return measured
    }

    /// One file's true length.
    ///
    /// `AVURLAssetPreferPreciseDurationAndTimingKey`, because the default is not
    /// a measurement at all for the format this book's audio is in: for a
    /// constant-bitrate MP3 with no length in its header, AVFoundation divides
    /// the file size by the bitrate and calls that the duration. The error is
    /// small per file and always in the same direction, so across a hundred and
    /// seventy-six chunks it sums into a book clock that disagrees with the
    /// audio by a visible amount — which is the one thing this type exists to
    /// prevent, and the estimate it was written to replace.
    ///
    /// Precise timing makes AVFoundation walk the file's frames instead, which
    /// is slower the first time a large read-along is opened. It is a one-time
    /// cost: the answers go through `save` and every later launch reads them
    /// back from `load` without opening a single audio file.
    private static func duration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(
            url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let time = try? await asset.load(.duration) else { return nil }
        let seconds = time.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}
