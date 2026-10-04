import Foundation
import Testing

@testable import IssaEPUB

/// What plays when an audio file runs out: the first entry of the next file,
/// whichever entry of this one was playing.
///
/// The end of a file used to ask for the entry after the one playing. In a run
/// the CTC aligner left out of time order, the clip playing at the end is the
/// one that ends last, which need not be the run's last entry, so the entry
/// after it was another clip of the same file: the advance seeked back into
/// the file, it played out and ended on the same clip, and it seeked back
/// again, for ever. The chapter never changed, so an end-of-chapter sleep
/// timer never fired.
@Suite("The end of an audio file hands on to the next file")
struct SMILFileEndTests {
    ///      0  a  a.mp3  0–5
    ///      1  b  a.mp3  10–15   heard last, ends last
    ///      2  c  a.mp3  5–10    listed last
    ///      3  d  b.mp3  0–5
    static func outOfOrder() -> SMILTimeline {
        narration([
            ("a", "c.xhtml", "a.mp3", 0, 5, false),
            ("b", "c.xhtml", "a.mp3", 10, 15, false),
            ("c", "c.xhtml", "a.mp3", 5, 10, false),
            ("d", "d.xhtml", "b.mp3", 0, 5, false),
        ])
    }

    @Test("from any clip of an out-of-order file, the next file's first entry")
    func outOfOrderFile() {
        let timeline = Self.outOfOrder()
        let entries = timeline.entries
        for index in 0 ... 2 {
            #expect(timeline.entry(followingFileOf: entries[index]) == entries[3], "from entry \(index)")
        }
    }

    /// A pin, and the reason for the test above: the clip playing when the
    /// file runs out is "b", and the entry after it is back in the same file.
    @Test("the entry playing at the end of that file is not its last, and the one after it is the same file")
    func whyPositionIsNotEnough() {
        let timeline = Self.outOfOrder()
        let entries = timeline.entries
        #expect(timeline.entry(inFile: "a.mp3", at: 15) == entries[1])
        #expect(timeline.entry(following: entries[1]) == entries[2])
        #expect(entries[2].audioHref == entries[1].audioHref)
    }

    ///      0  s0         a.mp3  0–5
    ///      1  s0  hole   a.mp3  5–21   over audio the next two go on to read
    ///      2  s1         a.mp3  10–15
    ///      3  s2         a.mp3  15–20
    ///      4  t0         b.mp3  0–5
    @Test("a file ending in a hole that spans the clips after it hands on to the next file")
    func holeOverTheLastClips() {
        let timeline = narration([
            ("s0", "c.xhtml", "a.mp3", 0, 5, false),
            ("s0", "c.xhtml", "a.mp3", 5, 21, true),
            ("s1", "c.xhtml", "a.mp3", 10, 15, false),
            ("s2", "c.xhtml", "a.mp3", 15, 20, false),
            ("t0", "d.xhtml", "b.mp3", 0, 5, false),
        ])
        let entries = timeline.entries
        #expect(timeline.entry(inFile: "a.mp3", at: 25) == entries[1], "the hole ends last")
        #expect(timeline.entry(following: entries[1]) == entries[2], "and positionally is followed by s1")
        for index in 0 ... 3 {
            #expect(timeline.entry(followingFileOf: entries[index]) == entries[4], "from entry \(index)")
        }
    }

    /// Where the entry is the last of its file — every file end the two
    /// fixtures have, v2's and v3's, including v3's out-of-order chapter
    /// three, which also ends the book — the new question has the old answer.
    @Test("at the last entry of every file in both fixtures, the answer is the entry after it",
          arguments: ["v2", "v3"])
    func sameAnswerAtEveryFileEnd(_ fixture: String) throws {
        let timeline = fixture == "v2" ? try SMILV2GoldenTests.timeline() : try SMILV3Tests.timeline()
        let entries = timeline.entries
        let fileEnds = entries.indices.filter { index in
            index == entries.count - 1 || entries[index + 1].audioHref != entries[index].audioHref
        }
        #expect(fileEnds.count >= 2)
        for index in fileEnds {
            #expect(timeline.entry(followingFileOf: entries[index]) == timeline.entry(following: entries[index]),
                    "at entry \(index)")
        }
    }

    @Test("from the middle of a file, the first entry of the next file")
    func fromMidFile() throws {
        let v2 = try SMILV2GoldenTests.timeline()
        #expect(v2.entry(followingFileOf: v2.entries[0]) == v2.entries[4])
        #expect(v2.entry(followingFileOf: v2.entries[4]) == nil, "track2 ends the book")

        // v3: from ch01-s0 to the audio chapter, over the rest of track1; a
        // sentence continued into track2b goes on to it.
        let v3 = try SMILV3Tests.timeline()
        #expect(v3.entry(followingFileOf: v3.entries[1]) == v3.entries[7])
        #expect(v3.entry(followingFileOf: v3.entries[10]) == v3.entries[11])
        #expect(v3.entry(followingFileOf: v3.entries[13]) == nil, "track3 ends the book")
    }

    /// Each run of a file the spine plays twice hands on to what follows that
    /// run. Which run is playing when the file ends is `entry(inFile:at:)`'s
    /// answer, and past the end that is always the last — see
    /// `entry(followingFileOf:)`.
    @Test("each run of a file that plays twice hands on to what follows that run")
    func repeatedFile() throws {
        let timeline = RepeatedAudioFileTests.timeline()
        let entries = timeline.entries
        #expect(timeline.entry(followingFileOf: entries[0]) == entries[1])
        #expect(timeline.entry(followingFileOf: entries[1]) == entries[3])
        #expect(timeline.entry(followingFileOf: entries[2]) == entries[3])
        #expect(timeline.entry(followingFileOf: entries[3]) == nil)
    }
}

/// A narration stated row by row, `cumulativeEnd` accumulated exactly as
/// `SMILParser.timeline(from:)` accumulates it.
private func narration(
    _ rows: [(fragment: String, text: String, audio: String,
              start: TimeInterval, end: TimeInterval, audioOnly: Bool)],
) -> SMILTimeline {
    var cumulative: TimeInterval = 0
    return SMILTimeline(entries: rows.map { row in
        cumulative += row.end - row.start
        return SMILEntry(
            fragmentID: row.fragment, textHref: row.text, audioHref: row.audio,
            start: row.start, end: row.end, cumulativeEnd: cumulative, isAudioOnly: row.audioOnly)
    })
}
