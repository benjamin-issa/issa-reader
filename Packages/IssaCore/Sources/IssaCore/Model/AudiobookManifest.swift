import Foundation

/// A Readium audiobook manifest, as `GET /books/{uuid}/listen/manifest.json`
/// returns it.
///
/// Captured from a live 2.14.21 server: the reading order is one entry per
/// track with a title, a duration and a relative href. Two traps are folded in
/// below — a single-file audiobook advertises an `m4b` alternate link that
/// always 404s, and the file extension follows the server's transcoding
/// setting, so nothing may assume `.mp3`.
public struct AudiobookManifest: Codable, Hashable, Sendable {
    public var metadata: Metadata
    public var readingOrder: [Track]
    public var links: [Link]?
    public var toc: [Track]?

    public struct Metadata: Codable, Hashable, Sendable {
        /// Readium states titles per language: `{"und": "Peter and Wendy"}`.
        public var title: [String: String]?
        public var subtitle: [String: String]?
        public var language: [String]?
        public var duration: Double?

        /// The title in whatever language the server offered.
        public var displayTitle: String? {
            guard let title, !title.isEmpty else { return nil }
            return title["en"] ?? title["und"] ?? title.sorted { $0.key < $1.key }.first?.value
        }
    }

    public struct Track: Codable, Hashable, Sendable, Identifiable {
        public var href: String
        public var type: String?
        public var title: String?
        public var duration: Double?
        public var size: Int?
        public var bitrate: Double?
        public var rel: [String]?

        public var id: String { href }
    }

    public struct Link: Codable, Hashable, Sendable {
        public var href: String
        public var type: String?
        public var rel: [String]?
    }

    /// The tracks worth playing.
    ///
    /// Anything with no duration is dropped: the m4b alternate link the server
    /// advertises for a single-file audiobook has none, and following it always
    /// 404s. Chapters are the reading order, not the links.
    public var playableTracks: [Track] {
        readingOrder.filter { ($0.duration ?? 0) > 0 }
    }

    /// Total running time, preferring the sum of the tracks over the stated
    /// metadata: a book whose metadata says `00:00:00` still plays.
    public var totalDuration: TimeInterval {
        let summed = playableTracks.reduce(0) { $0 + ($1.duration ?? 0) }
        return summed > 0 ? summed : (metadata.duration ?? 0)
    }

    /// Chapter titles, falling back to a track number rather than to nothing.
    public func title(of track: Track, at index: Int) -> String {
        if let title = track.title, !title.isEmpty { return title }
        return "Track \(index + 1)"
    }

    /// Where a track starts within the whole book, for a single scrubber over
    /// a book split across many files.
    public func startTime(ofTrackAt index: Int) -> TimeInterval {
        playableTracks.prefix(index).reduce(0) { $0 + ($1.duration ?? 0) }
    }

    /// The track playing at a point in the book, and how far into it.
    public func locate(bookTime: TimeInterval) -> (index: Int, offset: TimeInterval)? {
        let tracks = playableTracks
        guard !tracks.isEmpty else { return nil }
        var remaining = max(0, bookTime)
        for (index, track) in tracks.enumerated() {
            let duration = track.duration ?? 0
            if remaining < duration || index == tracks.count - 1 {
                return (index, min(remaining, duration))
            }
            remaining -= duration
        }
        return (tracks.count - 1, 0)
    }
}
