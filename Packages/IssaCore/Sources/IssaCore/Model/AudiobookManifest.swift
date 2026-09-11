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

    /// Built in code, not only decoded.
    ///
    /// A read-along's audio is the EPUB's own narration chunks, and the track
    /// list the server serves for the same book is the original upload — one
    /// file where the overlay has a hundred and seventy-six. The two never
    /// match, so the read-along path synthesises a manifest over the chunks
    /// instead. It is built through this initialiser rather than through a
    /// second manifest type, so everything downstream — the book clock, the
    /// anchor bridge, the locator written back to the server — is the same code
    /// either way.
    public init(
        metadata: Metadata,
        readingOrder: [Track],
        links: [Link]? = nil,
        toc: [Track]? = nil,
    ) {
        self.metadata = metadata
        self.readingOrder = readingOrder
        self.links = links
        self.toc = toc
    }

    public struct Metadata: Codable, Hashable, Sendable {
        /// Readium states titles per language: `{"und": "Peter and Wendy"}`.
        public var title: [String: String]?
        public var subtitle: [String: String]?
        public var language: [String]?
        public var duration: Double?

        /// Spelled out rather than left to the memberwise initialiser, because
        /// a manifest is now built in code as well as decoded: the read-along
        /// path synthesises one from the book's own media overlay. The labels
        /// and the defaults are exactly the memberwise ones, so nothing that
        /// already writes `.init(title:)` has to change.
        public init(
            title: [String: String]? = nil,
            subtitle: [String: String]? = nil,
            language: [String]? = nil,
            duration: Double? = nil,
        ) {
            self.title = title
            self.subtitle = subtitle
            self.language = language
            self.duration = duration
        }

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

        /// See `Metadata.init`: the memberwise labels and defaults, made
        /// public so a synthesised manifest is built through the same type the
        /// server's is decoded into rather than a parallel one.
        public init(
            href: String,
            type: String? = nil,
            title: String? = nil,
            duration: Double? = nil,
            size: Int? = nil,
            bitrate: Double? = nil,
            rel: [String]? = nil,
        ) {
            self.href = href
            self.type = type
            self.title = title
            self.duration = duration
            self.size = size
            self.bitrate = bitrate
            self.rel = rel
        }
    }

    public struct Link: Codable, Hashable, Sendable {
        public var href: String
        public var type: String?
        public var rel: [String]?

        public init(href: String, type: String? = nil, rel: [String]? = nil) {
            self.href = href
            self.type = type
            self.rel = rel
        }
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
    ///
    /// **The exact inverse of `startTime(ofTrackAt:)`**, which is a promise
    /// rather than an accident: `locate(bookTime: startTime(ofTrackAt: k))` must
    /// be `(k, 0)` for every `k`, and for a while it was not. This used to
    /// subtract each duration off a running remainder while `startTime` added
    /// them up from the left, and two roundings of one sum do not agree — on
    /// four tracks of `100.1` seconds, `startTime(ofTrackAt: 3)` is
    /// `300.29999999999995`, a ULP short of the three durations this walk had
    /// already taken off, so the residual stayed below the third boundary and
    /// the answer came back as *the end of track two*. Over two hundred random
    /// forty-track books with fractional durations, 46.7% of the boundaries
    /// disagreed.
    ///
    /// It reads as a read-along problem and is not. When no chapter list is
    /// supplied — every book playing the server's own manifest —
    /// `AudiobookCoordinator` makes each chapter start exactly
    /// `startTime(ofTrackAt:)`, so "previous, to restart this chapter" loaded
    /// the *previous* track a fraction of a second from its end on about half
    /// the chapters of every streamed audiobook. It ran out within the second,
    /// `advance()` read that as a chapter ending, and an armed end-of-chapter
    /// sleep timer stopped the book. `AudioAnchor.bookTime(for:)` sums the same
    /// way, so a resume landed a chunk early too.
    ///
    /// So the boundary is compared against a *running total* built by the same
    /// left fold `startTime` uses, which makes the two bit-identical rather than
    /// merely close. No binary search, and deliberately no cache: this is a
    /// struct with a mutable `readingOrder`, and a cache over it would be a
    /// second answer waiting to go stale.
    public func locate(bookTime: TimeInterval) -> (index: Int, offset: TimeInterval)? {
        let tracks = playableTracks
        guard !tracks.isEmpty else { return nil }
        // `max(0, .nan)` is `0` in Swift — a comparison against NaN is false, so
        // the other operand wins — which is what a non-finite clock has always
        // resolved to here, and what `BookClockTests` feeds this on purpose.
        // Kept, not corrected: refusing it would be a new contract.
        let target = max(0, bookTime)
        var start: TimeInterval = 0
        for (index, track) in tracks.enumerated() {
            let duration = track.duration ?? 0
            let end = start + duration
            if target < end || index == tracks.count - 1 {
                return (index, min(max(0, target - start), duration))
            }
            start = end
        }
        return (tracks.count - 1, 0)
    }
}
