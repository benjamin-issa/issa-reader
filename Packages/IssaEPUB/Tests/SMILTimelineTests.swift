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

/// A scrub to the far end of the bar lands exactly on `totalDuration`. The
/// strictly-greater search had no entry for it, so the scrub did nothing.
@Suite("The end of the book")
struct TimelineEndTests {
    @Test("exactly the total duration is the last sentence, not nowhere")
    func endIsLastEntry() throws {
        let timeline = SMILParser.timeline(for: try SMILTimelineTests.package())
        let last = try #require(timeline.entries.last)
        #expect(timeline.entry(atBookTime: timeline.totalDuration)?.fragmentID == last.fragmentID)
        #expect(timeline.entry(atBookTime: timeline.totalDuration + 5)?.fragmentID == last.fragmentID)
        // Inside the last entry is unchanged.
        #expect(timeline.entry(atBookTime: last.cumulativeEnd - last.duration / 2)?.fragmentID == last.fragmentID)
    }
}

/// The window the ten-foot read-along screen shows around the spoken sentence.
@Suite("A window of sentences around the one being read")
struct SMILTimelineWindowTests {
    private func timeline() throws -> SMILTimeline {
        SMILParser.timeline(for: try SMILTimelineTests.package())
    }

    @Test("the window is centred on the entry, in reading order")
    func centredOnTheEntry() throws {
        let timeline = try timeline()
        // The middle of whatever the fixture holds, so the assertion is about
        // the window and not about how many sentences somebody put in an EPUB.
        let index = timeline.entries.count / 2
        let middle = timeline.entries[index]
        let window = try #require(timeline.window(around: middle, before: 2, after: 2))

        #expect(window.currentIndex == 2)
        #expect(window.entries[window.currentIndex].fragmentID == middle.fragmentID)
        // The neighbours are the ones the linked-list walk would have found.
        #expect(window.entries[1].fragmentID == timeline.entry(before: middle)?.fragmentID)
        if window.entries.count > 3 {
            #expect(window.entries[3].fragmentID == timeline.entry(after: middle)?.fragmentID)
        }
        // Never more than asked for, and never past the ends of the book.
        #expect(window.entries.count <= 5)
        #expect(window.entries.count == min(timeline.entries.count, index + 3) - max(0, index - 2))
    }

    /// Clamped rather than padded: a short window at the start of a book is
    /// honest, and blank lines in the column would read as pauses.
    @Test("the start of the book yields a short window, not blanks")
    func clampsAtTheStart() throws {
        let timeline = try timeline()
        let first = try #require(timeline.entries.first)
        let window = try #require(timeline.window(around: first, before: 3, after: 3))

        #expect(window.currentIndex == 0)
        #expect(window.entries.count == min(4, timeline.entries.count))
        #expect(window.entries[0].fragmentID == first.fragmentID)
    }

    @Test("the end of the book clamps too")
    func clampsAtTheEnd() throws {
        let timeline = try timeline()
        let last = try #require(timeline.entries.last)
        let window = try #require(timeline.window(around: last, before: 3, after: 3))

        let expected = min(4, timeline.entries.count)
        #expect(window.entries.count == expected)
        #expect(window.currentIndex == expected - 1)
        #expect(window.entries[window.currentIndex].fragmentID == last.fragmentID)
    }

    @Test("a radius of nothing is just the entry")
    func zeroRadius() throws {
        let timeline = try timeline()
        let entry = timeline.entries[timeline.entries.count / 2]
        let window = try #require(timeline.window(around: entry, before: 0, after: 0))

        #expect(window.entries.count == 1)
        #expect(window.currentIndex == 0)
    }

    @Test("a fragment this timeline has never heard of has no window")
    func unknownFragment() throws {
        let timeline = try timeline()
        let stranger = SMILEntry(
            fragmentID: "not-in-this-book", textHref: "x.xhtml", audioHref: "x.mp4",
            start: 0, end: 1, cumulativeEnd: 1)
        #expect(timeline.window(around: stranger, before: 1, after: 1) == nil)
    }
}

@Suite("Fragment ids are unique per document, not per book")
struct ScopedFragmentTests {
    /// A book that numbers sentences from scratch in every chapter — legal,
    /// and what any aligner other than Storyteller's produces.
    private func timeline() -> SMILTimeline {
        var entries: [SMILEntry] = []
        var cumulative: TimeInterval = 0
        for chapter in 1 ... 3 {
            for sentence in 1 ... 3 {
                cumulative += 10
                entries.append(SMILEntry(
                    fragmentID: "s\(sentence)",
                    textHref: "OEBPS/ch0\(chapter).xhtml",
                    audioHref: "OEBPS/ch0\(chapter).mp3",
                    start: 0, end: 10, cumulativeEnd: cumulative))
            }
        }
        return SMILTimeline(entries: entries)
    }

    @Test("next sentence stays in the chapter it was asked about")
    func nextStaysPut() throws {
        let line = timeline()
        let third = try #require(line.entry(forFragment: "s1", inDocument: "OEBPS/ch03.xhtml"))
        #expect(third.textHref == "OEBPS/ch03.xhtml")

        let next = try #require(line.entry(after: third))
        #expect(
            next.textHref == "OEBPS/ch03.xhtml",
            "resolving by id alone sent this to chapter 1's second sentence")
        #expect(next.fragmentID == "s2")
    }

    @Test("previous sentence likewise")
    func previousStaysPut() throws {
        let line = timeline()
        let entry = try #require(line.entry(forFragment: "s2", inDocument: "OEBPS/ch02.xhtml"))
        let previous = try #require(line.entry(before: entry))
        #expect(previous.textHref == "OEBPS/ch02.xhtml")
        #expect(previous.fragmentID == "s1")
    }

    /// The read-along screen shows sentences either side of the spoken one.
    @Test("the window comes from the right chapter")
    func windowStaysPut() throws {
        let line = timeline()
        let entry = try #require(line.entry(forFragment: "s2", inDocument: "OEBPS/ch03.xhtml"))
        let window = try #require(line.window(around: entry, before: 1, after: 1))
        #expect(window.entries.allSatisfy { $0.textHref == "OEBPS/ch03.xhtml" })
    }

    @Test("an unscoped lookup still answers, with the first occurrence")
    func unscopedFallsBack() throws {
        let line = timeline()
        let entry = try #require(line.entry(forFragment: "s1"))
        #expect(entry.textHref == "OEBPS/ch01.xhtml", "documented as best effort")
    }
}

@Suite("A document the spine visits twice has two spans, not one")
struct RepeatedDocumentSpanTests {
    /// notes → chapter → notes. Legal: a shared page referenced twice.
    private func timeline() -> SMILTimeline {
        let rows: [(String, TimeInterval)] = [
            ("OEBPS/notes.xhtml", 2), ("OEBPS/ch01.xhtml", 12),
            ("OEBPS/ch01.xhtml", 22), ("OEBPS/notes.xhtml", 24),
        ]
        var entries: [SMILEntry] = []
        for (index, row) in rows.enumerated() {
            entries.append(SMILEntry(
                fragmentID: "f\(index)", textHref: row.0, audioHref: "a.mp3",
                start: 0, end: 2, cumulativeEnd: row.1))
        }
        return SMILTimeline(entries: entries)
    }

    /// The merged range ran 0 → 24, swallowing chapter one's twenty seconds.
    @Test("the first run does not swallow what lies between the two")
    func firstRunIsItsOwn() throws {
        let span = try #require(timeline().span(ofDocument: "OEBPS/notes.xhtml"))
        #expect(span.start == 0)
        #expect(span.duration == 2, "a 2-second page, not a 24-second one")
    }

    @Test("and the second run is reported where it actually is")
    func secondRunIsItsOwn() throws {
        let line = timeline()
        let second = try #require(line.entries.last)
        let span = try #require(line.span(ofDocumentContaining: second))
        #expect(span.start == 22)
        #expect(span.duration == 2)
    }

    /// One run, spanning both of its entries: the first ends at 12 after a
    /// 2-second clip, so it begins at 10, and the second ends at 22.
    @Test("a document visited once is unchanged")
    func singleRunUnchanged() throws {
        let span = try #require(timeline().span(ofDocument: "OEBPS/ch01.xhtml"))
        #expect(span.start == 10)
        #expect(span.duration == 12)
    }
}
