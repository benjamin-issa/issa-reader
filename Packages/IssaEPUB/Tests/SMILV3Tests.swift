import Foundation
import Testing

@testable import IssaEPUB

/// Built against `readalong-v3.epub`, which `make-readalong-fixture.py --v3`
/// writes the way Storyteller 3's aligner does: holes before and after
/// sentences that name the sentence's fragment, a sentence continued into the
/// next file, a two-file audio chapter behind chapter one, and clips that run
/// backwards inside one file.
///
/// The timeline it parses to, one row per entry, for reading the tests below:
///
///      0  ch01-s0  before-hole   track1   0–6.5
///      1  ch01-s0                track1   6.5–10.75
///      2  ch01-s0  after-hole    track1   10.75–17
///      3  ch01-s1                track1   17–24.25      (s2 is a 1 ms filler)
///      4  ch01-s3                track1   24.251–30.65  (s4 is a footnote)
///      5  ch01-s5                track1   30.65–35.75
///      6  ch01-s5  after-hole    track1   35.75–44      to the end of the file
///      7  storyteller_audio_1-s0 bonus1   0–180         audio chapter, -a0
///      8  storyteller_audio_1-s0 bonus2   0–150         audio chapter, -a1
///      9  ch02-s0                track2a  0–5
///     10  ch02-s1                track2a  5–9.75
///     11  ch02-s1  -a1           track2b  0–3.5         continuation
///     12  ch02-s2                track2b  3.5–8
///     13  ch03-s0                track3   0–4
///     14  ch03-s1                track3   14–19         heard after s2 and s3
///     15  ch03-s2                track3   4–9
///     16  ch03-s3                track3   9–14
///     17  ch03-s4                track3   21–25         (19–21 is a gap)
///     18  ch03-s4  after-hole    track3   25–33         the end of the book
@Suite("A v3-aligned book reads like the v2 book it replaces")
struct SMILV3Tests {
    static func package() throws -> EPUBPackage {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/readalong-v3", withExtension: "epub"))
        return try EPUBPackage.open(url: url)
    }

    static func timeline() throws -> SMILTimeline {
        SMILParser.timeline(for: try package())
    }

    static let track1 = "OEBPS/Audio/track1.mp3"
    static let track3 = "OEBPS/Audio/track3.mp3"

    @Test("the fixture parses to the layout the tests are written against")
    func layout() throws {
        let entries = try Self.timeline().entries
        #expect(entries.map(\.fragmentID) == [
            "ch01-s0", "ch01-s0", "ch01-s0", "ch01-s1", "ch01-s3", "ch01-s5", "ch01-s5",
            "storyteller_audio_1-s0", "storyteller_audio_1-s0",
            "ch02-s0", "ch02-s1", "ch02-s1", "ch02-s2",
            "ch03-s0", "ch03-s1", "ch03-s2", "ch03-s3", "ch03-s4", "ch03-s4",
        ])
        #expect(entries[7].textHref == "OEBPS/storyteller-audio-1.xhtml")
        #expect(entries[7].audioHref == "OEBPS/Audio/bonus1.mp3")
        #expect(entries[8].audioHref == "OEBPS/Audio/bonus2.mp3")
        #expect(entries[11].audioHref == "OEBPS/Audio/track2b.mp3")
    }

    // MARK: - Parsing

    /// Holes and audio-chapter pars, and nothing else. The continuation at 11
    /// carries its sentence's own state, and the words it is reading are real.
    @Test("only the pars typed audio-only are audio-only")
    func audioOnlyFlags() throws {
        let entries = try Self.timeline().entries
        let flagged = entries.indices.filter { entries[$0].isAudioOnly }
        #expect(flagged == [0, 2, 6, 7, 8, 18])
    }

    /// `epub:type` is a token list; the aligner puts two tokens on its
    /// word-granular seqs, and a par may carry more than one as well.
    @Test("the type is read as a token list, not compared whole")
    func typeIsATokenList() throws {
        let smil = """
            <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
              <body><seq>
                <par id="a" epub:type="storyteller:audio-only  extra">
                  <text src="c.xhtml#a"/><audio src="a.mp3" clipBegin="0s" clipEnd="1s"/>
                </par>
                <par id="b" epub:type="storyteller:audio-onlyish">
                  <text src="c.xhtml#b"/><audio src="a.mp3" clipBegin="1s" clipEnd="2s"/>
                </par>
                <par id="c">
                  <text src="c.xhtml#c"/><audio src="a.mp3" clipBegin="2s" clipEnd="3s"/>
                </par>
              </seq></body>
            </smil>
            """
        let rows = try SMILParser.parse(data: Data(smil.utf8), overlayHref: "OEBPS/x.smil")
        #expect(rows.map { $0.isAudioOnly } == [true, false, false])
    }

    // MARK: - Sentence navigation

    /// v2 folded a hole's seconds into the sentence it names, so being in the
    /// hole is being in that sentence, and the next sentence is the one after.
    @Test("next sentence from a sentence's hole, the sentence or its after-hole is the one after it")
    func nextFromEveryPartOfASentence() throws {
        let timeline = try Self.timeline()
        let entries = timeline.entries
        for index in [0, 1, 2] {
            #expect(timeline.entry(after: entries[index]) == entries[3],
                    "from entry \(index)")
        }
    }

    @Test("next sentence steps over an after-hole and a whole audio chapter")
    func nextSkipsTheAudioChapter() throws {
        let timeline = try Self.timeline()
        let entries = timeline.entries
        for index in [5, 6, 7, 8] {
            #expect(timeline.entry(after: entries[index]) == entries[9],
                    "from entry \(index)")
        }
    }

    @Test("next sentence steps over a continuation of the sentence it leaves")
    func nextSkipsAContinuation() throws {
        let timeline = try Self.timeline()
        let entries = timeline.entries
        #expect(timeline.entry(after: entries[10]) == entries[12])
        #expect(timeline.entry(after: entries[11]) == entries[12])
    }

    @Test("there is no next sentence after the last one, hole or not")
    func noNextAtTheEnd() throws {
        let timeline = try Self.timeline()
        let entries = timeline.entries
        #expect(timeline.entry(after: entries[17]) == nil)
        #expect(timeline.entry(after: entries[18]) == nil)
    }

    @Test("previous sentence from a continuation is the sentence before the one it continues")
    func previousFromAContinuation() throws {
        let timeline = try Self.timeline()
        let entries = timeline.entries
        #expect(timeline.entry(before: entries[11]) == entries[9])
    }

    /// Walking back, a sentence that runs across files is met at its
    /// continuation; landing there would start it part-way through.
    @Test("previous sentence lands on the start of a sentence that continues into another file")
    func previousLandsOnTheSentenceNotItsContinuation() throws {
        let timeline = try Self.timeline()
        let entries = timeline.entries
        #expect(timeline.entry(before: entries[12]) == entries[10])
    }

    @Test("previous sentence lands on the sentence, not the holes around it")
    func previousSkipsHoles() throws {
        let timeline = try Self.timeline()
        let entries = timeline.entries
        // ch01-s1 back to ch01-s0's own par, past its after-hole and in front
        // of its before-hole.
        #expect(timeline.entry(before: entries[3]) == entries[1])
        // ch02-s0 back over the audio chapter and ch01-s5's after-hole.
        #expect(timeline.entry(before: entries[9]) == entries[5])
        #expect(timeline.entry(before: entries[0]) == nil)
        #expect(timeline.entry(before: entries[1]) == nil)
    }

    // MARK: - The end of a file

    /// The loop: ch01's file ends in ch01-s5's after-hole. What plays next is
    /// the audio chapter, not the hole again and not chapter two.
    @Test("the entry following a file-ending after-hole is the audio chapter")
    func followingAFileEndingHole() throws {
        let timeline = try Self.timeline()
        let entries = timeline.entries
        let next = try #require(timeline.entry(following: entries[6]))
        #expect(next == entries[7])
        #expect(next.fragmentID == "storyteller_audio_1-s0")
        #expect(next.audioHref == "OEBPS/Audio/bonus1.mp3")
        #expect(timeline.entry(following: entries[7]) == entries[8])
        #expect(timeline.entry(following: entries[8]) == entries[9])
    }

    @Test("the entry following is positional: a sentence's own hole and continuation count")
    func followingIsPositional() throws {
        let timeline = try Self.timeline()
        let entries = timeline.entries
        #expect(timeline.entry(following: entries[5]) == entries[6])
        #expect(timeline.entry(following: entries[10]) == entries[11])
        #expect(timeline.entry(following: entries[18]) == nil, "the end of the book")
    }

    // MARK: - Identity

    /// A hole and its sentence share a fragment. Resolving the hole by that
    /// fragment used to hand back the sentence, so everything positional about
    /// it was measured from the wrong place.
    @Test("a hole is its own place in the book, not its sentence's")
    func aHoleIsItsOwnPlace() throws {
        let timeline = try Self.timeline()
        let entries = timeline.entries
        let window = try #require(timeline.window(around: entries[2], before: 1, after: 1))
        #expect(window.entries == [entries[1], entries[2], entries[3]])
        #expect(window.entries[window.currentIndex] == entries[2])

        // And its chapter span is its own document's, the audio chapter's
        // included: 44 s of chapter one before it, five and a half minutes long.
        let hole = try #require(timeline.span(ofDocumentContaining: entries[6]))
        let chapterOne = try #require(timeline.span(ofDocument: "OEBPS/ch01.xhtml"))
        #expect(hole.start == chapterOne.start)
        #expect(hole.duration == chapterOne.duration)
        let interlude = try #require(timeline.span(ofDocumentContaining: entries[8]))
        #expect(abs(interlude.start - entries[6].cumulativeEnd) < 0.000_1)
        #expect(abs(interlude.duration - 330) < 0.000_1)
    }

    /// Tap and seek keep the first entry for a fragment. For a sentence with a
    /// hole in front that is the hole, which is where v2's clip for the same
    /// sentence began.
    @Test("a fragment still resolves to its first entry")
    func fragmentsResolveToTheirFirstEntry() throws {
        let timeline = try Self.timeline()
        let entries = timeline.entries
        #expect(timeline.entry(forFragment: "ch01-s0", inDocument: "OEBPS/ch01.xhtml") == entries[0])
        #expect(timeline.entry(forFragment: "storyteller_audio_1-s0") == entries[7])
    }

    // MARK: - Clips that run backwards

    @Test("a run whose clips go backwards is looked up by what is playing, not by order",
          arguments: [
              (2.0, 13), (4.0, 15), (6.0, 15), (9.0, 16), (11.0, 16),
              (14.0, 14), (16.0, 14), (22.0, 17), (25.0, 18), (30.0, 18),
          ])
    func backwardsRun(_ time: TimeInterval, _ expected: Int) throws {
        let timeline = try Self.timeline()
        #expect(timeline.entry(inFile: Self.track3, at: time) == timeline.entries[expected])
    }

    @Test("a gap inside a backwards run is no sentence, and past its end is its last")
    func backwardsRunGapAndEnd() throws {
        let timeline = try Self.timeline()
        #expect(timeline.entry(inFile: Self.track3, at: 20) == nil, "19–21 carries no clip")
        #expect(timeline.entry(inFile: Self.track3, at: 40) == timeline.entries[18])
    }

    @Test("a run that ascends is searched as before, holes included")
    func ascendingRunUnchanged() throws {
        let timeline = try Self.timeline()
        let entries = timeline.entries
        #expect(timeline.entry(inFile: Self.track1, at: 3) == entries[0])
        #expect(timeline.entry(inFile: Self.track1, at: 6.5) == entries[1])
        #expect(timeline.entry(inFile: Self.track1, at: 12) == entries[2])
        #expect(timeline.entry(inFile: Self.track1, at: 24.2505) == nil,
                "the dropped filler's millisecond is nobody's, as it was in v2")
        #expect(timeline.entry(inFile: Self.track1, at: 40) == entries[6])
        #expect(timeline.entry(inFile: Self.track1, at: 99) == entries[6])
        #expect(timeline.entry(inFile: "OEBPS/Audio/track2b.mp3", at: 1) == entries[11])
        #expect(timeline.entry(inFile: "OEBPS/Audio/bonus2.mp3", at: 75) == entries[8])
    }

    /// The overlap CTC actually leaves: a hole over audio that the next pars
    /// go on to narrate. Every time in 10–20 is inside the hole too, and a
    /// binary search stops there; the sentence being read began later.
    @Test("where clips overlap, the one that began most recently is playing")
    func overlapPicksTheLatestStart() {
        let clips: [(String, TimeInterval, TimeInterval, Bool)] = [
            ("a", 0, 5, false), ("a", 5, 20, true), ("b", 10, 15, false), ("c", 15, 20, false),
        ]
        var cumulative: TimeInterval = 0
        let entries = clips.map { clip in
            cumulative += clip.2 - clip.1
            return SMILEntry(
                fragmentID: clip.0, textHref: "c.xhtml", audioHref: "a.mp3",
                start: clip.1, end: clip.2, cumulativeEnd: cumulative, isAudioOnly: clip.3)
        }
        let timeline = SMILTimeline(entries: entries)
        #expect(timeline.entry(inFile: "a.mp3", at: 2) == entries[0])
        #expect(timeline.entry(inFile: "a.mp3", at: 7) == entries[1])
        #expect(timeline.entry(inFile: "a.mp3", at: 12) == entries[2])
        #expect(timeline.entry(inFile: "a.mp3", at: 17) == entries[3])
        #expect(timeline.entry(inFile: "a.mp3", at: 25) == entries[3], "the later of the two that end last")
    }
}

/// `readalong.epub` is v2 output, and v2 books must behave exactly as they did
/// before the timeline learned about v3.
///
/// The list below was taken from the implementation *before* that change, so
/// it pins the parse — every field, to the last bit of every sum — and the
/// navigation checks pin that a book with no audio-only entries and one entry
/// per fragment steps exactly as it always stepped: to the next and previous
/// entry by position.
@Suite("A v2-aligned book is unchanged")
struct SMILV2GoldenTests {
    static func timeline() throws -> SMILTimeline {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        return SMILParser.timeline(for: try EPUBPackage.open(url: url))
    }

    static let golden: [SMILEntry] = [
        ("ch01-s0", "OEBPS/ch01.xhtml", "OEBPS/Audio/track1.mp3", 0.0, 4.25, 4.25),
        ("ch01-s1", "OEBPS/ch01.xhtml", "OEBPS/Audio/track1.mp3", 4.25, 11.5, 11.5),
        ("ch01-s3", "OEBPS/ch01.xhtml", "OEBPS/Audio/track1.mp3", 11.501, 17.9, 17.899),
        ("ch01-s5", "OEBPS/ch01.xhtml", "OEBPS/Audio/track1.mp3", 17.9, 23.0, 22.999000000000002),
        ("ch02-s0", "OEBPS/ch02.xhtml", "OEBPS/Audio/track2.mp3", 0.0, 5.0, 27.999000000000002),
        ("ch02-s1", "OEBPS/ch02.xhtml", "OEBPS/Audio/track2.mp3", 5.0, 9.75, 32.749),
    ].map {
        SMILEntry(
            fragmentID: $0.0, textHref: $0.1, audioHref: $0.2,
            start: $0.3, end: $0.4, cumulativeEnd: $0.5, isAudioOnly: false)
    }

    @Test("every entry parses exactly as it did")
    func entriesUnchanged() throws {
        let entries = try Self.timeline().entries
        #expect(entries == Self.golden)
        #expect(entries.allSatisfy { !$0.isAudioOnly })
    }

    @Test("next and previous sentence are the next and previous entry")
    func navigationIsPositional() throws {
        let timeline = try Self.timeline()
        let entries = timeline.entries
        for index in entries.indices {
            let next = index + 1 < entries.count ? entries[index + 1] : nil
            let previous = index > 0 ? entries[index - 1] : nil
            #expect(timeline.entry(after: entries[index]) == next, "after \(index)")
            #expect(timeline.entry(following: entries[index]) == next, "following \(index)")
            #expect(timeline.entry(before: entries[index]) == previous, "before \(index)")
        }
    }

    @Test("every clip's midpoint finds that clip, and past a file's end finds its last")
    func clipLookupUnchanged() throws {
        let timeline = try Self.timeline()
        for entry in timeline.entries {
            #expect(timeline.entry(inFile: entry.audioHref, at: (entry.start + entry.end) / 2) == entry)
        }
        #expect(timeline.entry(inFile: "OEBPS/Audio/track1.mp3", at: 9_999)?.fragmentID == "ch01-s5")
        #expect(timeline.entry(inFile: "OEBPS/Audio/track2.mp3", at: 9_999)?.fragmentID == "ch02-s1")
    }
}
