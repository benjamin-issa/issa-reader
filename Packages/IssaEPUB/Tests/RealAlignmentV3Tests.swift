import Foundation
import Testing

@testable import IssaEPUB

/// Runs against read-along EPUBs produced by a real Storyteller 3 alignment.
///
/// `readalong-v3.epub` proves the parser handles the v3 grammar as the aligner's
/// source describes it; these prove it handles what a web-v3.0.0-beta.40 server
/// actually wrote. Neither file is committed — each embeds its audio — and each
/// test is skipped when its file is absent, so the suite stays green on a clean
/// checkout. Produce them against the `--profile v3` server in Tools/docker:
/// narrate a two-chapter public-domain text with `say`, with the headings read
/// aloud and digital silence placed around it, import the EPUB and the audio by
/// path (`POST /api/v2/books {"paths": […]}`), `POST /api/v2/books/{id}/process`,
/// then `GET /api/v2/books/{id}/files?format=readaloud`.
///
/// - `/tmp/pw3-loop.epub`: two tracks, the first ending in eight seconds of
///   silence after chapter one's last sentence. v3 writes that as an
///   after-hole which is the last entry of a file that is not the book's last:
///   the shape that made 1.2.0 replay the hole for ever.
/// - `/tmp/pw3.epub`: the same, with five minutes of silence at the chapter
///   boundary instead, which v3 turns into an audio-only chapter spanning both
///   tracks, and eight seconds after the last sentence, which ends the book on
///   a hole.
struct RealAlignmentV3Tests {
    static let loopPath = "/tmp/pw3-loop.epub"
    static let interludePath = "/tmp/pw3.epub"

    static var loopAvailable: Bool { FileManager.default.fileExists(atPath: loopPath) }
    static var interludeAvailable: Bool { FileManager.default.fileExists(atPath: interludePath) }

    static func timeline(_ path: String) throws -> (SMILTimeline, EPUBPackage) {
        let package = try EPUBPackage.open(url: URL(fileURLWithPath: path))
        return (SMILParser.timeline(for: package), package)
    }

    @Test("a file that ends in an after-hole hands on to the next file, not back to the hole",
          .enabled(if: RealAlignmentV3Tests.loopAvailable))
    func fileEndingInAHole() throws {
        let (timeline, _) = try Self.timeline(Self.loopPath)
        let entries = timeline.entries
        let firstFile = try #require(entries.first?.audioHref)
        let lastOfFirstFile = try #require(entries.last { $0.audioHref == firstFile })
        #expect(lastOfFirstFile.isAudioOnly, "the server wrote no after-hole at the end of the first track")

        let following = try #require(timeline.entry(following: lastOfFirstFile))
        #expect(following.audioHref != firstFile, "the end of the file went back into the same file")

        let nextSentence = try #require(timeline.entry(after: lastOfFirstFile))
        #expect(!nextSentence.isAudioOnly)
        #expect(nextSentence.fragmentID != lastOfFirstFile.fragmentID)
    }

    @Test("an audio-only chapter is played through and stepped over",
          .enabled(if: RealAlignmentV3Tests.interludeAvailable))
    func audioOnlyChapter() throws {
        let (timeline, package) = try Self.timeline(Self.interludePath)
        let entries = timeline.entries
        let interlude = entries.filter { $0.textHref.contains("storyteller-audio-") }
        #expect(!interlude.isEmpty, "the server wrote no audio-only chapter")
        #expect(interlude.allSatisfy { $0.isAudioOnly })
        #expect(Set(interlude.map(\.audioHref)).count == 2, "expected the chapter to span both tracks")
        #expect(package.spine.contains { $0.href.contains("storyteller-audio-") })

        // The last sentence before it.
        let firstInterlude = try #require(interlude.first)
        let before = try #require(entries.last {
            !$0.isAudioOnly && $0.cumulativeEnd < firstInterlude.cumulativeEnd
        })
        // The end of its audio plays the chapter; "next sentence" skips it.
        #expect(timeline.entry(following: before) == firstInterlude)
        let skipped = try #require(timeline.entry(after: before))
        #expect(!skipped.textHref.contains("storyteller-audio-"))
        #expect(!skipped.isAudioOnly)

        // And the book closes on a hole, after which there is nothing.
        let last = try #require(entries.last)
        #expect(last.isAudioOnly)
        #expect(timeline.entry(following: last) == nil)
    }

    @Test("every v3 entry is coherent",
          .enabled(if: RealAlignmentV3Tests.loopAvailable || RealAlignmentV3Tests.interludeAvailable))
    func entriesAreCoherent() throws {
        for path in [Self.loopPath, Self.interludePath] where FileManager.default.fileExists(atPath: path) {
            let (timeline, package) = try Self.timeline(path)
            #expect(timeline.entries.contains { $0.isAudioOnly }, "\(path) has no audio-only entries")
            var previous: TimeInterval = 0
            for entry in timeline.entries {
                #expect(entry.duration >= SMILParser.minimumMeaningfulDuration)
                #expect(entry.cumulativeEnd > previous, "cumulative time went backwards at \(entry.fragmentID)")
                previous = entry.cumulativeEnd
                #expect(package.archive.contains(entry.audioHref), "missing audio \(entry.audioHref)")
                #expect(package.archive.contains(entry.textHref), "missing text \(entry.textHref)")
                // Forward, always: it only is when every entry, holes included,
                // resolves to its own place rather than to its sentence's first.
                #expect(timeline.entry(following: entry).map { $0.cumulativeEnd > entry.cumulativeEnd } ?? true)
            }
            // The server aligns by the sentence, so no entry is a word of one:
            // resolving and stepping are exactly what they were before words
            // were read.
            #expect(timeline.entries.allSatisfy { $0.sentenceID == nil }, "\(path) has a word-granular entry")
        }
    }
}
