import Foundation
import Testing

@testable import IssaEPUB

/// Runs against read-along EPUBs produced by a real Storyteller 3 alignment.
///
/// `readalong-v3.epub` proves the parser handles the v3 grammar as the aligner's
/// source describes it; these prove it handles what a 3.x server actually
/// wrote. Neither book is committed — each embeds its audio — so both live in
/// the local stack's store, one folder per server tag, and are copied to `/tmp`
/// for a run:
///
/// | Server | Store (`Tools/docker/data/real-alignment/<tag>/`) | Staged as |
/// | --- | --- | --- |
/// | `web-v3.0.0-beta.46` | `pw3.epub`, `pw3-loop.epub` | `/tmp/pw3.epub`, `/tmp/pw3-loop.epub` |
/// | `web-v3.0.0-beta.40` | `pw3.epub`, `pw3-loop.epub` | `/tmp/pw3-beta40.epub`, `/tmp/pw3-loop-beta40.epub` |
///
/// Every test runs once per server whose pair is staged, so a newer beta is
/// checked without losing the older one the app still has to read. A pair that
/// is absent is skipped, so the suite stays green on a clean checkout — except
/// on a release run (`ISSA_RELEASE_RUN=1`, see `ReleaseRun`), where every file
/// of every pair must be present and an absent one fails the test that needed it.
///
/// Both books are "The Gap Book", a two-chapter public-domain text narrated with
/// `say`, with the headings read aloud and digital silence placed around it.
/// Produce them against the `--profile v3` server in Tools/docker: import the
/// EPUB and the audio by path (`POST /api/v2/books {"paths": […]}`),
/// `POST /api/v2/books/{id}/process`, then
/// `GET /api/v2/books/{id}/files?format=readaloud`, and file the result under
/// the server's tag.
///
/// - `pw3-loop.epub` ("The Gap Book"): two tracks, the first ending in eight
///   seconds of silence after chapter one's last sentence. v3 writes that as an
///   after-hole which is the last entry of a file that is not the book's last:
///   the shape that made 1.2.0 replay the hole for ever.
/// - `pw3.epub` ("The Gap Book, Announced"): the same, with five minutes of
///   silence at the chapter boundary instead, which v3 turns into an audio-only
///   chapter spanning both tracks, and eight seconds after the last sentence,
///   which ends the book on a hole.
struct RealAlignmentV3Tests {
    /// One server generation's pair of aligned books.
    struct Pair: Sendable, CustomTestStringConvertible {
        /// The server tag that aligned them, which is also their folder in
        /// `Tools/docker/data/real-alignment/`.
        let tag: String
        /// The book with the audio-only chapter (`pw3.epub` in the store).
        let interludePath: String
        /// The book whose first file ends in an after-hole (`pw3-loop.epub`).
        let loopPath: String

        var paths: [String] { [interludePath, loopPath] }
        var testDescription: String { tag }
    }

    /// Newest first: the pinned beta, then the one before it.
    static let pairs = [
        Pair(tag: "web-v3.0.0-beta.46", interludePath: "/tmp/pw3.epub", loopPath: "/tmp/pw3-loop.epub"),
        Pair(
            tag: "web-v3.0.0-beta.40",
            interludePath: "/tmp/pw3-beta40.epub", loopPath: "/tmp/pw3-loop-beta40.epub"),
    ]

    /// Whether anything at all can run: on a release run always, where an
    /// absent file is `require`'s to report; otherwise when any file is staged.
    static var anyAvailable: Bool {
        ReleaseRun.isOn || pairs.flatMap(\.paths).contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Whether `path` is here to read, recording an issue on a release run when
    /// it is not. A skip otherwise — one pair staged without the other is an
    /// ordinary checkout.
    static func present(_ path: String) -> Bool {
        if ReleaseRun.isOn { return ReleaseRun.require([path]) }
        return FileManager.default.fileExists(atPath: path)
    }

    static func timeline(_ path: String) throws -> (SMILTimeline, EPUBPackage) {
        let package = try EPUBPackage.open(url: URL(fileURLWithPath: path))
        return (SMILParser.timeline(for: package), package)
    }

    @Test("a file that ends in an after-hole hands on to the next file, not back to the hole",
          .enabled(if: RealAlignmentV3Tests.anyAvailable), arguments: RealAlignmentV3Tests.pairs)
    func fileEndingInAHole(_ pair: Pair) throws {
        guard Self.present(pair.loopPath) else { return }
        let (timeline, _) = try Self.timeline(pair.loopPath)
        let entries = timeline.entries
        let firstFile = try #require(entries.first?.audioHref)
        let lastOfFirstFile = try #require(entries.last { $0.audioHref == firstFile })
        #expect(lastOfFirstFile.isAudioOnly, "\(pair.tag) wrote no after-hole at the end of the first track")

        let following = try #require(timeline.entry(following: lastOfFirstFile))
        #expect(following.audioHref != firstFile, "the end of the file went back into the same file")
        #expect(timeline.entry(followingFileOf: lastOfFirstFile) == following)

        let nextSentence = try #require(timeline.entry(after: lastOfFirstFile))
        #expect(!nextSentence.isAudioOnly)
        #expect(nextSentence.fragmentID != lastOfFirstFile.fragmentID)
    }

    @Test("an audio-only chapter is played through and stepped over",
          .enabled(if: RealAlignmentV3Tests.anyAvailable), arguments: RealAlignmentV3Tests.pairs)
    func audioOnlyChapter(_ pair: Pair) throws {
        guard Self.present(pair.interludePath) else { return }
        let (timeline, package) = try Self.timeline(pair.interludePath)
        let entries = timeline.entries
        let interlude = entries.filter { $0.textHref.contains("storyteller-audio-") }
        #expect(!interlude.isEmpty, "\(pair.tag) wrote no audio-only chapter")
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
        #expect(timeline.entry(followingFileOf: last) == nil)
    }

    @Test("every v3 entry is coherent",
          .enabled(if: RealAlignmentV3Tests.anyAvailable), arguments: RealAlignmentV3Tests.pairs)
    func entriesAreCoherent(_ pair: Pair) throws {
        // Each path on its own, so a release run with one absent records it
        // and still checks the other, rather than running on half its input
        // and passing.
        for path in pair.paths where Self.present(path) {
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
                // And the end of whichever file this entry is in goes forward,
                // into another file.
                #expect(timeline.entry(followingFileOf: entry).map {
                    $0.cumulativeEnd > entry.cumulativeEnd && $0.audioHref != entry.audioHref
                } ?? true)
            }
            // The server aligns by the sentence, so no entry is a word of one:
            // resolving and stepping are exactly what they were before words
            // were read.
            #expect(timeline.entries.allSatisfy { $0.sentenceID == nil }, "\(path) has a word-granular entry")
        }
    }

    // MARK: R-70 — the staged files are the server's they claim to be

    /// The Storyteller version a book's package says aligned it: the
    /// `storyteller:version` meta every 2.x and 3.x server writes into
    /// `content.opf`.
    static func alignedBy(_ path: String) throws -> String? {
        let archive = try EPUBPackage.open(url: URL(fileURLWithPath: path)).archive
        let container = String(decoding: try archive.read("META-INF/container.xml"), as: UTF8.self)
        guard let opf = container.firstMatch(of: /full-path="([^"]+)"/)?.1 else { return nil }
        let package = String(decoding: try archive.read(String(opf)), as: UTF8.self)
        return package.firstMatch(of: /<meta property="storyteller:version">\s*([^<\s]+)\s*<\/meta>/)
            .map { String($0.1) }
    }

    /// The staged files of `pair` that some other server aligned, each with
    /// the version it names. Absent files are not this question's business.
    static func misattributed(_ pair: Pair) throws -> [String] {
        let expected = String(pair.tag.trimmingPrefix("web-v"))
        return try pair.paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .compactMap { path in
                let version = try alignedBy(path)
                return version == expected ? nil : "\(path) was aligned by \(version ?? "an unknown version")"
            }
    }

    /// The books are told apart only by where they are staged, and the
    /// beta.46 slot reuses the `/tmp` paths 1.3.0 used for beta.40's. A
    /// machine still holding those ran the newer pin's cases on the older
    /// server's output and passed them. Each book names the server that
    /// aligned it, so each pair's staged files must name that pair's tag.
    @Test("the staged books were aligned by the server their slot names",
          .enabled(if: RealAlignmentV3Tests.anyAvailable), arguments: RealAlignmentV3Tests.pairs)
    func stagedBooksAreTheirServers(_ pair: Pair) throws {
        for path in pair.paths { _ = Self.present(path) }
        let wrong = try Self.misattributed(pair)
        #expect(wrong.isEmpty, "\(pair.tag)'s slot holds another server's books: \(wrong)")
    }

    /// The guard itself, on the mix-up it exists for: beta.40's books in the
    /// beta.46 slot.
    @Test("a slot holding an older server's books is caught",
          .enabled(if: RealAlignmentV3Tests.pairs[1].paths.allSatisfy {
              FileManager.default.fileExists(atPath: $0)
          }))
    func staleBooksAreCaught() throws {
        let older = Self.pairs[1]
        let stale = Pair(tag: Self.pairs[0].tag, interludePath: older.interludePath, loopPath: older.loopPath)
        #expect(try Self.misattributed(stale).count == 2)
        #expect(try Self.misattributed(older).isEmpty)
    }
}
