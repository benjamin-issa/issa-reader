import Foundation

/// Parses SMIL clock values.
///
/// Storyteller writes clip times as `"12.345s"`, and package-level durations as
/// `"HH:MM:SS.ss"`. Both forms are legal SMIL, and both appear in the same book,
/// so a reader must handle the full grammar rather than just the one it expects.
public enum SMILClock {
    public static func seconds(from raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Metric forms: 12.345s, 1.5min, 2h, 300ms.
        if value.hasSuffix("ms") {
            return Double(value.dropLast(2)).map { $0 / 1000 }
        }
        if value.hasSuffix("s") { return Double(value.dropLast()) }
        if value.hasSuffix("min") { return Double(value.dropLast(3)).map { $0 * 60 } }
        if value.hasSuffix("h") { return Double(value.dropLast()).map { $0 * 3600 } }

        // Clock forms: HH:MM:SS.mmm or MM:SS.mmm.
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ Double($0) != nil }) else {
            return Double(value)
        }
        return parts.reduce(0.0) { total, part in total * 60 + (Double(part) ?? 0) }
    }
}

/// One narrated fragment: a span of audio bound to a fragment of text.
public struct SMILEntry: Sendable, Hashable {
    /// Fragment id inside the text document, e.g. `chapter_one-s42`.
    public let fragmentID: String
    /// Archive path of the text document this fragment lives in.
    public let textHref: String
    /// Archive path of the audio file.
    public let audioHref: String
    public let start: TimeInterval
    public let end: TimeInterval
    /// Running total of clip durations up to and including this entry, forming
    /// a gapless virtual timeline for the whole book. This is NOT an offset into
    /// any single audio file.
    public let cumulativeEnd: TimeInterval

    public var duration: TimeInterval { max(0, end - start) }
}

/// The whole book's narration, flattened and searchable.
///
/// Built once when a book is opened. Lookup is a binary search rather than the
/// linear scan a naive implementation uses, because this runs on every audio
/// tick while the reader is on screen.
public struct SMILTimeline: Sendable {
    public let entries: [SMILEntry]
    /// Fragment id to entry index, for seeking from a tapped word.
    private let indexByFragment: [String: Int]
    /// Contiguous runs of entries belonging to each audio file, in the order
    /// they occur in the book — usually one run, occasionally more when a file
    /// (a shared intro or outro clip) is referenced from more than one place in
    /// the spine, with some other file's entries in between.
    ///
    /// Never merged into a single spanning range: a widened range for two
    /// far-apart runs of the same file would include whatever other files'
    /// entries fall between them, and since clip times restart near zero per
    /// file, a binary search over that span could return a different file's
    /// entry entirely for a `time` that happens to fall inside both — silently
    /// mis-highlighting or mis-seeking while the correct audio keeps playing.
    private let fileRanges: [String: [Range<Int>]]
    /// The same, per text document — which is what a reader calls a chapter.
    private let documentRanges: [String: Range<Int>]

    public var totalDuration: TimeInterval { entries.last?.cumulativeEnd ?? 0 }
    public var isEmpty: Bool { entries.isEmpty }

    public init(entries: [SMILEntry]) {
        self.entries = entries
        var index: [String: Int] = [:]
        index.reserveCapacity(entries.count)
        // First occurrence wins: ids are unique in practice, and if a book
        // repeats one, seeking to the earlier position is the safer reading.
        for (i, entry) in entries.enumerated() where index[entry.fragmentID] == nil {
            index[entry.fragmentID] = i
        }
        indexByFragment = index

        var ranges: [String: [Range<Int>]] = [:]
        var start = 0
        while start < entries.count {
            let href = entries[start].audioHref
            var end = start + 1
            while end < entries.count, entries[end].audioHref == href { end += 1 }
            // A file may legitimately appear in more than one run. Recorded as
            // a separate range each time rather than widened into one — see
            // the property's doc comment for why widening is the bug.
            ranges[href, default: []].append(start ..< end)
            start = end
        }
        fileRanges = ranges

        // The same shape again, keyed by text document. Built here rather than
        // filtered on demand because a progress bar scoped to the chapter asks
        // for this on every tick, and `entries.filter` walks the whole book.
        var documents: [String: Range<Int>] = [:]
        start = 0
        while start < entries.count {
            let href = entries[start].textHref
            var end = start + 1
            while end < entries.count, entries[end].textHref == href { end += 1 }
            if let existing = documents[href] {
                documents[href] = min(existing.lowerBound, start) ..< max(existing.upperBound, end)
            } else {
                documents[href] = start ..< end
            }
            start = end
        }
        documentRanges = documents
    }

    /// Where one text document's narration sits on the virtual book timeline.
    ///
    /// A "chapter" for a read-along is a spine document. Gutenberg books pack
    /// several chapters into one file, so this can be coarser than the chapter
    /// name shown beside it — but it is the only boundary the media overlay
    /// actually knows.
    public func span(ofDocument href: String) -> (start: TimeInterval, duration: TimeInterval)? {
        guard let range = documentRanges[href], !range.isEmpty else { return nil }
        let first = entries[range.lowerBound]
        let last = entries[range.upperBound - 1]
        let start = first.cumulativeEnd - first.duration
        let duration = last.cumulativeEnd - start
        guard duration > 0 else { return nil }
        return (start, duration)
    }

    /// The entry playing at `time` on the virtual book timeline.
    public func entry(atBookTime time: TimeInterval) -> SMILEntry? {
        index(atBookTime: time).map { entries[$0] }
    }

    public func index(atBookTime time: TimeInterval) -> Int? {
        guard !entries.isEmpty else { return nil }
        // The end of the book is the last sentence, not nowhere: a scrub to
        // the far end of the bar lands exactly on `totalDuration`, which the
        // strictly-greater search below has no entry for, and the scrub was
        // silently a no-op. The audiobook manifest makes the same exception
        // for its last track.
        if time >= entries[entries.count - 1].cumulativeEnd { return entries.count - 1 }
        // Strictly-greater search: a time exactly on a boundary belongs to the
        // entry that starts there, not the one that ends there.
        var low = 0
        var high = entries.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if entries[mid].cumulativeEnd > time {
                result = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return result
    }

    /// Where a fragment sits on the virtual timeline, for seeking.
    public func bookTime(forFragment fragmentID: String) -> TimeInterval? {
        guard let index = indexByFragment[fragmentID] else { return nil }
        let entry = entries[index]
        return entry.cumulativeEnd - entry.duration
    }

    public func entry(forFragment fragmentID: String) -> SMILEntry? {
        indexByFragment[fragmentID].map { entries[$0] }
    }

    /// Fraction of the book narrated, 0...1.
    public func progression(atBookTime time: TimeInterval) -> Double {
        guard totalDuration > 0 else { return 0 }
        return min(max(time / totalDuration, 0), 1)
    }

    /// The entries belonging to one text document, in reading order.
    public func entries(inDocument href: String) -> [SMILEntry] {
        entries.filter { $0.textHref == href }
    }

    /// The entry playing at `time` seconds within a specific audio file.
    ///
    /// This is the per-tick lookup while audio plays. It is scoped to one file
    /// because clip times restart at zero in each track, so a book-time search
    /// would match the wrong sentence entirely.
    public func entry(inFile audioHref: String, at time: TimeInterval) -> SMILEntry? {
        // Entries within one run are contiguous and ordered, so each run is
        // bound and binary searched on its own — never across a gap that might
        // hold another file's entries. See `fileRanges`.
        guard let runs = fileRanges[audioHref], !runs.isEmpty else { return nil }
        for range in runs {
            var low = range.lowerBound
            var high = range.upperBound - 1
            while low <= high {
                let mid = (low + high) / 2
                let entry = entries[mid]
                if time < entry.start {
                    high = mid - 1
                } else if time >= entry.end {
                    low = mid + 1
                } else {
                    return entry
                }
            }
        }
        // A time past the last clip belongs to the final entry rather than
        // nothing: clips are gapless within a file, so this only happens at the
        // very end — of the file's last run, in the rare case it has more than
        // one.
        let lastRun = runs[runs.count - 1]
        if time >= entries[lastRun.upperBound - 1].end {
            return entries[lastRun.upperBound - 1]
        }
        return nil
    }

    /// The entry that follows `entry` in reading order, if any.
    public func entry(after entry: SMILEntry) -> SMILEntry? {
        guard let index = indexByFragment[entry.fragmentID], index + 1 < entries.count else { return nil }
        return entries[index + 1]
    }

    public func entry(before entry: SMILEntry) -> SMILEntry? {
        guard let index = indexByFragment[entry.fragmentID], index > 0 else { return nil }
        return entries[index - 1]
    }

    /// The run of entries around `entry`, and where in that run it sits.
    ///
    /// A window rather than repeated `entry(before:)` calls: the ten-foot
    /// read-along screen shows several sentences either side of the spoken one,
    /// and walking the linked list N times to build a list the timeline can
    /// slice directly is work for nothing. Clamped at both ends, so the window
    /// is short at the start and end of a book rather than padded with blanks.
    ///
    /// Returns `nil` only when the fragment is not in this timeline at all.
    public func window(
        around entry: SMILEntry, before: Int, after: Int
    ) -> (entries: [SMILEntry], currentIndex: Int)? {
        guard let index = indexByFragment[entry.fragmentID] else { return nil }
        let lower = max(0, index - max(before, 0))
        let upper = min(entries.count - 1, index + max(after, 0))
        return (Array(entries[lower ... upper]), index - lower)
    }

    /// First entry of each text document, for chapter navigation.
    public func firstEntry(inDocument href: String) -> SMILEntry? {
        entries.first { $0.textHref == href }
    }

    /// The first narrated entry belonging to any of `documents`.
    ///
    /// Entries are built by walking the spine in order, so passing the spine
    /// *from a reader's chapter onwards* answers "where does narration next
    /// begin, at or after here" in a single pass — which is the question
    /// somebody pressing play on a partly aligned book is actually asking.
    /// Answering it with `entries.first` answers a different question, the start
    /// of the whole audiobook, and that is what read a reader's book back to
    /// them from page one and then saved the position.
    public func firstEntry(inAnyOf documents: some Sequence<String>) -> SMILEntry? {
        let wanted = Set(documents)
        return entries.first { wanted.contains($0.textHref) }
    }
}

public enum SMILParser {
    /// Clips shorter than this are structural padding, not narration.
    ///
    /// Storyteller's aligner emits ~1 ms entries so that EPUBCheck accepts a
    /// zero-length range. Matching one would make the highlight flicker onto a
    /// fragment that is never actually spoken, so they are dropped.
    static let minimumMeaningfulDuration: TimeInterval = 0.005

    /// Parses one SMIL document into entries.
    ///
    /// Handles the three nesting depths the format allows: the chapter `seq`,
    /// an optional `text-range-large` seq per block, an optional
    /// `text-range-small` seq per sentence, and finally `par` elements. A
    /// server-aligned book is always a flat list of sentence `par`s, but books
    /// aligned by the CLI can be word-granular.
    public static func parse(
        data: Data, overlayHref: String,
    ) throws -> [(fragmentID: String, textHref: String, audioHref: String, start: TimeInterval, end: TimeInterval)] {
        let root = try EPUBXML.parse(data)
        var results: [(String, String, String, TimeInterval, TimeInterval)] = []

        func walk(_ node: EPUBXMLNode) {
            for child in node.children {
                switch child.name {
                case "par":
                    guard let textNode = child.firstChild("text"),
                          let src = textNode["src"],
                          let audioNode = child.firstChild("audio"),
                          let audioSrc = audioNode["src"]
                    else { continue }

                    let fragment = src.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                    guard !fragment.isEmpty else { continue }

                    let start = SMILClock.seconds(from: audioNode["clipBegin"] ?? "") ?? 0
                    let end = SMILClock.seconds(from: audioNode["clipEnd"] ?? "") ?? start

                    results.append((
                        fragment,
                        EPUBPackage.resolve(src, relativeTo: overlayHref),
                        EPUBPackage.resolve(audioSrc, relativeTo: overlayHref),
                        start,
                        end,
                    ))
                case "seq", "body":
                    walk(child)
                default:
                    walk(child)
                }
            }
        }
        walk(root)
        return results.map {
            (fragmentID: $0.0, textHref: $0.1, audioHref: $0.2, start: $0.3, end: $0.4)
        }
    }

    /// Builds the whole-book timeline by walking the spine in order.
    ///
    /// Spine items with no overlay are skipped silently — a book may have
    /// narration for only some chapters, and the front matter usually has none.
    public static func timeline(for package: EPUBPackage) -> SMILTimeline {
        var entries: [SMILEntry] = []
        var cumulative: TimeInterval = 0

        for item in package.spine {
            guard let overlayID = item.mediaOverlayID,
                  let overlay = package.manifest[overlayID],
                  let data = try? package.archive.read(overlay.href),
                  let parsed = try? parse(data: data, overlayHref: overlay.href)
            else { continue }

            for row in parsed {
                let duration = max(0, row.end - row.start)
                guard duration >= minimumMeaningfulDuration else { continue }
                cumulative += duration
                entries.append(SMILEntry(
                    fragmentID: row.fragmentID,
                    textHref: row.textHref,
                    audioHref: row.audioHref,
                    start: row.start,
                    end: row.end,
                    cumulativeEnd: cumulative,
                ))
            }
        }
        return SMILTimeline(entries: entries)
    }
}
