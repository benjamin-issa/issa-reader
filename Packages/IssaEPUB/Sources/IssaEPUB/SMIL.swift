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
    }

    /// The entry playing at `time` on the virtual book timeline.
    public func entry(atBookTime time: TimeInterval) -> SMILEntry? {
        index(atBookTime: time).map { entries[$0] }
    }

    public func index(atBookTime time: TimeInterval) -> Int? {
        guard !entries.isEmpty else { return nil }
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
