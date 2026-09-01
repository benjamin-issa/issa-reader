import Foundation
import Testing

@testable import IssaEPUB

/// Built against a fixture that reproduces Storyteller's aligner output,
/// including the two things real output contains that break naive readers:
/// a ~1 ms filler entry, and a gap in sentence-id numbering left by a footnote.
struct SMILTimelineTests {
    static func package() throws -> EPUBPackage {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        return try EPUBPackage.open(url: url)
    }

    @Test("reads the media-overlay metadata the aligner writes")
    func readsOverlayMetadata() throws {
        let package = try Self.package()
        // Leading hyphen. The spec's usual example has none, so a reader that
        // assumes the default highlights nothing.
        #expect(package.metadata.mediaActiveClass == "-epub-media-overlay-active")
        #expect(package.metadata.mediaDuration != nil)
        #expect(package.spine.allSatisfy { $0.mediaOverlayID != nil })
    }

    @Test("builds a gapless book timeline across chapters")
    func buildsTimeline() throws {
        let timeline = SMILParser.timeline(for: try Self.package())
        #expect(!timeline.isEmpty)

        // The 1 ms filler entry must not appear.
        #expect(!timeline.entries.contains { $0.fragmentID == "ch01-s2" })
        #expect(timeline.entries.allSatisfy { $0.duration >= SMILParser.minimumMeaningfulDuration })

        // cumulativeEnd is a running total of clip durations, so it increases
        // strictly and spans chapters — it is not an offset into any one file.
        var previous: TimeInterval = 0
        for entry in timeline.entries {
            #expect(entry.cumulativeEnd > previous)
            previous = entry.cumulativeEnd
        }
        #expect(abs(timeline.totalDuration - previous) < 0.0001)
    }

    @Test("sentence ids are not contiguous, and that is fine")
    func handlesNonContiguousIDs() throws {
        let timeline = SMILParser.timeline(for: try Self.package())
        let chapterOne = timeline.entries.filter { $0.fragmentID.hasPrefix("ch01") }.map(\.fragmentID)
        // s2 is dropped as filler and s4 lives in the footnotes section.
        #expect(chapterOne == ["ch01-s0", "ch01-s1", "ch01-s3", "ch01-s5"])
    }

    @Test("a time on a boundary belongs to the entry that starts there")
    func boundaryGoesForward() throws {
        let timeline = SMILParser.timeline(for: try Self.package())
        let first = try #require(timeline.entries.first)
        // Exactly at the end of entry 0 should select entry 1, not entry 0.
        let atBoundary = try #require(timeline.entry(atBookTime: first.cumulativeEnd))
        #expect(atBoundary.fragmentID == timeline.entries[1].fragmentID)

        let inside = try #require(timeline.entry(atBookTime: first.cumulativeEnd - 0.001))
        #expect(inside.fragmentID == first.fragmentID)
    }

    @Test("looks up every entry by its own midpoint")
    func lookupIsExhaustive() throws {
        let timeline = SMILParser.timeline(for: try Self.package())
        for entry in timeline.entries {
            let midpoint = entry.cumulativeEnd - entry.duration / 2
            let found = try #require(timeline.entry(atBookTime: midpoint))
            #expect(found.fragmentID == entry.fragmentID,
                    "midpoint of \(entry.fragmentID) resolved to \(found.fragmentID)")
        }
    }

    @Test("seeking from a fragment id round-trips")
    func seekRoundTrips() throws {
        let timeline = SMILParser.timeline(for: try Self.package())
        for entry in timeline.entries {
            let time = try #require(timeline.bookTime(forFragment: entry.fragmentID))
            // Landing exactly on the start boundary must select this entry.
            let found = try #require(timeline.entry(atBookTime: time))
            #expect(found.fragmentID == entry.fragmentID)
        }
    }

    @Test("progression spans the whole book, across chapters")
    func progression() throws {
        let timeline = SMILParser.timeline(for: try Self.package())
        #expect(timeline.progression(atBookTime: 0) == 0)
        #expect(timeline.progression(atBookTime: timeline.totalDuration) == 1)
        // Clamped, never out of range.
        #expect(timeline.progression(atBookTime: -5) == 0)
        #expect(timeline.progression(atBookTime: timeline.totalDuration * 2) == 1)
    }

    @Test("entries carry the chapter and audio file they belong to")
    func entriesCarryHrefs() throws {
        let timeline = SMILParser.timeline(for: try Self.package())
        let chapterOne = timeline.entries(inDocument: "OEBPS/ch01.xhtml")
        #expect(!chapterOne.isEmpty)
        #expect(chapterOne.allSatisfy { $0.audioHref == "OEBPS/Audio/track1.mp3" })

        let chapterTwo = timeline.entries(inDocument: "OEBPS/ch02.xhtml")
        #expect(chapterTwo.allSatisfy { $0.audioHref == "OEBPS/Audio/track2.mp3" })
        // A second chapter restarts its clips at zero within its own file, while
        // the book timeline keeps climbing.
        #expect(chapterTwo.first?.start == 0)
        #expect((chapterTwo.first?.cumulativeEnd ?? 0) > (chapterOne.last?.cumulativeEnd ?? 0))
    }

    @Test("an unknown fragment does not resolve")
    func unknownFragment() throws {
        let timeline = SMILParser.timeline(for: try Self.package())
        #expect(timeline.bookTime(forFragment: "nope-s99") == nil)
        #expect(timeline.entry(forFragment: "nope-s99") == nil)
    }

    // MARK: - Where narration may begin

    /// The lookup that replaced `entries.first` as the fallback when a reader
    /// presses play and the visible page carries no narrated sentence. It must
    /// only ever look *forward*: answering with the start of the book is what
    /// read a part-read novel back from page one and then saved that position.
    @Test("finds the first narration at or after a reader's chapter")
    func findsNarrationAtOrAfterChapter() throws {
        let package = try Self.package()
        let timeline = SMILParser.timeline(for: package)
        let hrefs = package.spine.map(\.href)

        // From the first chapter, the answer is the first entry of the book.
        let fromStart = try #require(timeline.firstEntry(inAnyOf: hrefs))
        #expect(fromStart.fragmentID == timeline.entries.first?.fragmentID)

        // From the second chapter onwards it must NOT be the first entry.
        let laterHrefs = Array(hrefs.dropFirst())
        let fromLater = try #require(timeline.firstEntry(inAnyOf: laterHrefs))
        #expect(fromLater.textHref != fromStart.textHref)
        #expect(fromLater.fragmentID != timeline.entries.first?.fragmentID,
                "looking forward from chapter two must never answer with chapter one")
    }

    @Test("returns nothing when no document ahead is narrated")
    func findsNothingAhead() throws {
        let timeline = SMILParser.timeline(for: try Self.package())
        #expect(timeline.firstEntry(inAnyOf: ["OEBPS/not-a-real-document.xhtml"]) == nil)
        #expect(timeline.firstEntry(inAnyOf: [String]()) == nil)
    }

    @Test("answers with the earliest of the documents offered, in spine order")
    func answersInSpineOrder() throws {
        let package = try Self.package()
        let timeline = SMILParser.timeline(for: package)
        let hrefs = package.spine.map(\.href)
        // Offered in reverse, the answer is still the one that comes first in
        // the book — the set is a filter, not an ordering.
        let reversed = try #require(timeline.firstEntry(inAnyOf: hrefs.reversed()))
        #expect(reversed.fragmentID == timeline.entries.first?.fragmentID)
    }
}


/// A file referenced from more than one place in the spine, with a different
/// file's entries in between — an intro or outro clip shared across chapters.
///
/// `entry(inFile:at:)` used to bound its search with a *widened* range
/// spanning both runs, which included whatever fell between them. Since clip
/// times restart near zero per file, a `time` that legitimately belongs to the
/// interloping file could match — silently returning a different file's
/// sentence for the file actually asked about, while the correct audio kept
/// playing.
@Suite("A file appearing in more than one run")
struct RepeatedAudioFileTests {
    /// intro.mp3 plays 0-2s, then chapter1.mp3 plays 0-6s while intro.mp3 is
    /// silent, then intro.mp3 resumes at 5-7s. Time 3 is squarely inside
    /// chapter1.mp3's second sentence and inside the *gap* between intro.mp3's
    /// two runs — nowhere in intro.mp3 at all.
    static func timeline() -> SMILTimeline {
        SMILTimeline(entries: [
            SMILEntry(fragmentID: "intro-s0", textHref: "intro.xhtml", audioHref: "intro.mp3",
                      start: 0, end: 2, cumulativeEnd: 2),
            SMILEntry(fragmentID: "ch1-s0", textHref: "ch1.xhtml", audioHref: "chapter1.mp3",
                      start: 0, end: 3, cumulativeEnd: 5),
            SMILEntry(fragmentID: "ch1-s1", textHref: "ch1.xhtml", audioHref: "chapter1.mp3",
                      start: 3, end: 6, cumulativeEnd: 8),
            SMILEntry(fragmentID: "intro-s1", textHref: "intro.xhtml", audioHref: "intro.mp3",
                      start: 5, end: 7, cumulativeEnd: 10),
        ])
    }

    @Test("a time that falls in the gap between two runs of a file is not answered by the interloper's entry there")
    func doesNotBleedIntoTheGap() {
        let timeline = Self.timeline()
        // Squarely chapter1.mp3's second sentence, and in nobody's window in
        // intro.mp3 — the old widened range covered it anyway, via chapter1's
        // own entries sitting between intro's two runs.
        let entry = timeline.entry(inFile: "intro.mp3", at: 3)
        #expect(entry == nil,
                "intro.mp3 has nothing at its own time 3 — got \(entry?.fragmentID ?? "nil") instead")
    }

    @Test("each of the repeated file's own runs is still reachable at its own time")
    func bothRunsStillWork() {
        let timeline = Self.timeline()
        #expect(timeline.entry(inFile: "intro.mp3", at: 1)?.fragmentID == "intro-s0")
        #expect(timeline.entry(inFile: "intro.mp3", at: 6)?.fragmentID == "intro-s1")
    }

    @Test("the file in between is entirely unaffected by the file that surrounds it")
    func theInterlopingFileIsUnaffected() {
        let timeline = Self.timeline()
        #expect(timeline.entry(inFile: "chapter1.mp3", at: 1)?.fragmentID == "ch1-s0")
        #expect(timeline.entry(inFile: "chapter1.mp3", at: 4)?.fragmentID == "ch1-s1")
    }

    @Test("past the end of the repeated file's last run still falls back to its final entry")
    func pastTheEndFallsBackToTheLastRun() {
        let timeline = Self.timeline()
        #expect(timeline.entry(inFile: "intro.mp3", at: 999)?.fragmentID == "intro-s1")
    }

    @Test("an unknown file matches nothing")
    func unknownFile() {
        let timeline = Self.timeline()
        #expect(timeline.entry(inFile: "nowhere.mp3", at: 0) == nil)
    }
}
