import Foundation
import Testing

@testable import IssaEPUB

/// Runs against a readaloud EPUB produced by a real Storyteller alignment.
///
/// The synthetic fixture proves the parser handles the format as documented;
/// this proves it handles what the server actually emits. The file is large
/// (~79 MB for five hours of narration, since the aligner embeds the audio), so
/// it is not committed. Produce one with:
///
///   cd Tools/docker && PUBLIC_HOST=$(ipconfig getifaddr en0) node setup.mjs
///   # import a book with audio, POST /api/v2/books/{id}/process, then
///   curl -H "Authorization: Bearer $TOKEN" \
///     "$SERVER/api/v2/books/$UUID/files?format=readaloud" -o /tmp/pw2.epub
///
/// Skipped when the file is absent so the suite stays green on a clean checkout.
struct RealAlignmentTests {
    static let path = "/tmp/pw2.epub"

    static var available: Bool { FileManager.default.fileExists(atPath: path) }

    @Test("parses a real aligned EPUB into a usable timeline",
          .enabled(if: RealAlignmentTests.available))
    func parsesRealAlignment() throws {
        let package = try EPUBPackage.open(url: URL(fileURLWithPath: Self.path))
        let timeline = SMILParser.timeline(for: package)

        #expect(!timeline.isEmpty, "real alignment produced no timeline entries")
        // Five hours of narration is thousands of sentences.
        #expect(timeline.entries.count > 1000)
        #expect(timeline.totalDuration > 3600)

        // The aligner writes this with a leading hyphen, unlike the spec's usual
        // example, so a reader that assumes the default highlights nothing.
        #expect(package.metadata.mediaActiveClass == "-epub-media-overlay-active")
        #expect((package.metadata.mediaDuration ?? 0) > 3600)
    }

    @Test("every entry is coherent and the timeline is monotonic",
          .enabled(if: RealAlignmentTests.available))
    func entriesAreCoherent() throws {
        let package = try EPUBPackage.open(url: URL(fileURLWithPath: Self.path))
        let timeline = SMILParser.timeline(for: package)

        var previous: TimeInterval = 0
        for entry in timeline.entries {
            #expect(entry.end > entry.start, "\(entry.fragmentID) has a non-positive clip")
            #expect(entry.duration >= SMILParser.minimumMeaningfulDuration)
            #expect(entry.cumulativeEnd > previous, "cumulative time went backwards at \(entry.fragmentID)")
            previous = entry.cumulativeEnd
            #expect(package.archive.contains(entry.audioHref), "missing audio \(entry.audioHref)")
            #expect(package.archive.contains(entry.textHref), "missing text \(entry.textHref)")
        }
    }

    @Test("clips are contiguous within each track",
          .enabled(if: RealAlignmentTests.available))
    func clipsAreGaplessWithinTracks() throws {
        let package = try EPUBPackage.open(url: URL(fileURLWithPath: Self.path))
        let timeline = SMILParser.timeline(for: package)

        // The aligner collapses gaps so every second of a track belongs to some
        // sentence. Filler entries are dropped when the timeline is built, which
        // leaves small legitimate jumps, so this checks ordering rather than
        // exact adjacency.
        var lastByFile: [String: TimeInterval] = [:]
        for entry in timeline.entries {
            if let last = lastByFile[entry.audioHref] {
                #expect(entry.start >= last - 0.001,
                        "clips went backwards inside \(entry.audioHref) at \(entry.fragmentID)")
            }
            lastByFile[entry.audioHref] = entry.start
        }
        #expect(lastByFile.count > 1, "expected narration spread across several tracks")
    }

    @Test("every fragment resolves back to its own position",
          .enabled(if: RealAlignmentTests.available))
    func lookupsRoundTrip() throws {
        let package = try EPUBPackage.open(url: URL(fileURLWithPath: Self.path))
        let timeline = SMILParser.timeline(for: package)

        // Sample across the book rather than all several-thousand entries.
        for entry in stride(from: 0, to: timeline.entries.count, by: 97).map({ timeline.entries[$0] }) {
            let byFile = try #require(timeline.entry(inFile: entry.audioHref,
                                                     at: entry.start + entry.duration / 2))
            #expect(byFile.fragmentID == entry.fragmentID)

            let bookTime = try #require(timeline.bookTime(forFragment: entry.fragmentID))
            let byBookTime = try #require(timeline.entry(atBookTime: bookTime + entry.duration / 2))
            #expect(byBookTime.fragmentID == entry.fragmentID)
        }
    }

    @Test("the text fragments the SMIL references really exist in the markup",
          .enabled(if: RealAlignmentTests.available))
    func fragmentsExistInMarkup() throws {
        let package = try EPUBPackage.open(url: URL(fileURLWithPath: Self.path))
        let timeline = SMILParser.timeline(for: package)

        // Take one chapter and confirm its span ids are all present. This is
        // what makes highlighting possible at all: a fragment with no matching
        // element highlights nothing.
        let href = try #require(timeline.entries.first?.textHref)
        let html = String(decoding: try package.archive.read(href), as: UTF8.self)
        let chapterEntries = timeline.entries(inDocument: href)
        #expect(chapterEntries.count > 100)

        for entry in chapterEntries.prefix(200) {
            #expect(html.contains("id=\"\(entry.fragmentID)\""),
                    "markup has no element for \(entry.fragmentID)")
        }
    }
}
