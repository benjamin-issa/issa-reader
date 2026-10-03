import Foundation
import Testing

@testable import IssaEPUB

/// What the timeline needs to know about clips with no stated end, and how
/// fast it can find out.
@Suite("Clips with no stated end, at scale and awaiting their files")
struct SMILOpenClipLengthTests {
    static let chapter = "OEBPS/ch01.xhtml"

    static func row(_ id: String, _ audio: String, start: TimeInterval) -> SMILParser.Row {
        SMILParser.Row(
            fragmentID: id, textHref: chapter, audioHref: audio, start: start, end: start,
            isAudioOnly: false, sentenceID: nil, isOpenEnded: true)
    }

    /// R-13. A file whose last clip states no end needs that file's length,
    /// and only a reader that knows which files those are can measure them —
    /// once, and not every file of a book that never needed it.
    @Test("the files whose last clip waits on their length are named, until a length is given")
    func filesNeedingLengthAreNamed() {
        let rows = [
            Self.row("s1", "OEBPS/Audio/a.mp3", start: 0),
            Self.row("s2", "OEBPS/Audio/a.mp3", start: 4),
            Self.row("s3", "OEBPS/Audio/b.mp3", start: 0),
        ]
        let unmeasured = SMILParser.timeline(from: rows)
        #expect(unmeasured.filesNeedingLength == ["OEBPS/Audio/a.mp3", "OEBPS/Audio/b.mp3"])

        let half = SMILParser.timeline(from: rows, fileDurations: ["OEBPS/Audio/a.mp3": 9])
        #expect(half.filesNeedingLength == ["OEBPS/Audio/b.mp3"])

        let measured = SMILParser.timeline(
            from: rows, fileDurations: ["OEBPS/Audio/a.mp3": 9, "OEBPS/Audio/b.mp3": 7])
        #expect(measured.filesNeedingLength.isEmpty)
        #expect(measured.totalDuration == 16)
    }

    /// Every book either Storyteller generation aligned states its ends, and
    /// asks for nothing.
    @Test("a narration that states every end needs no file lengths")
    func statedEndsNeedNothing() {
        let rows = [SMILParser.Row(
            fragmentID: "s1", textHref: Self.chapter, audioHref: "OEBPS/Audio/a.mp3",
            start: 0, end: 3, isAudioOnly: false, sentenceID: nil, isOpenEnded: false)]
        #expect(SMILParser.timeline(from: rows).filesNeedingLength.isEmpty)
        #expect(SMILTimeline(entries: []).filesNeedingLength.isEmpty)
    }

    /// R-64. Each open clip found its successor by a linear scan of its
    /// file's sorted starts: quadratic in the clips one file holds, on the
    /// main actor at every open. Thirty thousand clipBegin-only clips in one
    /// long file is a third-party book, not a contrived one.
    @Test("thirty thousand open clips in one file resolve in well under a second")
    func manyOpenClipsResolveQuickly() throws {
        let count = 30_000
        // Shuffled, so the resolution cannot lean on the rows arriving in
        // order: the starts are sorted once, per file, whatever the order.
        let rows = (0 ..< count).map { Self.row("s\($0)", "OEBPS/Audio/long.mp3", start: Double($0)) }
            .shuffled()

        let started = ContinuousClock.now
        let resolved = SMILParser.resolvingOpenEnds(rows, fileDurations: [:])
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(1), "resolving took \(elapsed)")
        let byID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.fragmentID, $0) })
        for index in [0, 1, 4_999, 29_998] {
            let row = try #require(byID["s\(index)"])
            #expect(row.end == Double(index + 1), "s\(index) ends where the next clip begins")
        }
        let last = try #require(byID["s\(count - 1)"])
        #expect(last.end == Double(count - 1) + SMILParser.openClipPlaceholder)
    }

    /// Two clips that begin at the same moment: the next one *later* is the
    /// end, as the linear scan had it.
    @Test("a clip's end is the next start strictly after its own")
    func equalStartsLookPastEachOther() {
        let rows = [
            Self.row("a", "OEBPS/Audio/a.mp3", start: 2),
            Self.row("b", "OEBPS/Audio/a.mp3", start: 2),
            Self.row("c", "OEBPS/Audio/a.mp3", start: 5),
        ]
        let resolved = SMILParser.resolvingOpenEnds(rows, fileDurations: [:])
        #expect(resolved.map(\.end) == [5, 5, 5 + SMILParser.openClipPlaceholder])
    }
}
