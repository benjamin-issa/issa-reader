import Foundation
import Testing

@testable import IssaEPUB

/// A `par` whose `<audio>` states no `clipEnd`.
///
/// SMIL defines a missing `clipEnd` as "to the end of the media". The parser
/// read it as the clip's own start, so the par came out zero seconds long and
/// the minimum-duration filter dropped it as padding: the sentence never lit,
/// could not be tapped, and a whole-file par — an intro read over its heading,
/// a chapter aligned as one clip — took its file's audio out of the book.
/// Storyteller always writes `clipEnd`, so none of this reaches a book either
/// server aligned; a book from another toolchain can omit it.
@Suite("A clip with no stated end")
struct SMILOpenClipTests {
    static let overlay = "OEBPS/MediaOverlays/ch01.smil"
    static let chapter = "OEBPS/ch01.xhtml"

    /// `s1` and `s3` state no end; `s3` is the last clip of `a.mp3`. `s4` is a
    /// whole file, with neither end stated.
    static let smil = """
        <?xml version="1.0" encoding="utf-8"?>
        <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
          <body>
            <seq epub:textref="../ch01.xhtml" epub:type="chapter">
              <par id="p1">
                <text src="../ch01.xhtml#s1"/>
                <audio src="../Audio/a.mp3" clipBegin="0s"/>
              </par>
              <par id="p2">
                <text src="../ch01.xhtml#s2"/>
                <audio src="../Audio/a.mp3" clipBegin="4.5s" clipEnd="9s"/>
              </par>
              <par id="p3">
                <text src="../ch01.xhtml#s3"/>
                <audio src="../Audio/a.mp3" clipBegin="9s"/>
              </par>
              <par id="p4">
                <text src="../ch01.xhtml#s4"/>
                <audio src="../Audio/b.mp3"/>
              </par>
            </seq>
          </body>
        </smil>
        """

    static func rows() throws -> [SMILParser.Row] {
        try SMILParser.parse(data: Data(smil.utf8), overlayHref: overlay)
    }

    @Test("a clip with no end runs on to the next clip in its file")
    func runsToTheNextClip() throws {
        let timeline = SMILParser.timeline(from: try Self.rows())
        let first = try #require(
            timeline.entry(forFragment: "s1", inDocument: Self.chapter),
            "the par was dropped as a zero-length filler")
        #expect(first.start == 0)
        #expect(first.end == 4.5, "it ends where the next clip in a.mp3 begins")
        // And the one between keeps exactly what it stated.
        let second = try #require(timeline.entry(forFragment: "s2", inDocument: Self.chapter))
        #expect(second.start == 4.5)
        #expect(second.end == 9)
    }

    /// The last clip of a file, and a par that is a whole file, run to the
    /// file's end when its length is known.
    @Test("the last clip of a file with no end runs to the file's measured length")
    func runsToTheFilesEnd() throws {
        let timeline = SMILParser.timeline(from: try Self.rows(), fileDurations: [
            "OEBPS/Audio/a.mp3": 20, "OEBPS/Audio/b.mp3": 30,
        ])
        let third = try #require(timeline.entry(forFragment: "s3", inDocument: Self.chapter))
        #expect(third.start == 9)
        #expect(third.end == 20)
        let whole = try #require(timeline.entry(forFragment: "s4", inDocument: Self.chapter))
        #expect(whole.audioHref == "OEBPS/Audio/b.mp3")
        #expect(whole.start == 0)
        #expect(whole.end == 30, "the whole of b.mp3")
        #expect(timeline.totalDuration == 50, "and the book clock carries every second of both files")
    }

    /// With no length to hand — the reader parses the overlay before any
    /// audio is extracted — the clip is still kept, so its file plays and its
    /// sentence lights: it is the last clip of its file, which owns every time
    /// past its start.
    @Test("with no length known, an open last clip is kept and owns the rest of its file")
    func keptWithoutALength() throws {
        let timeline = SMILParser.timeline(from: try Self.rows())
        let third = try #require(timeline.entry(forFragment: "s3", inDocument: Self.chapter))
        let whole = try #require(timeline.entry(forFragment: "s4", inDocument: Self.chapter),
                                 "a whole-file par took its file out of the book")
        #expect(third.end > third.start)
        #expect(timeline.entry(inFile: "OEBPS/Audio/a.mp3", at: 15)?.fragmentID == "s3")
        #expect(timeline.entry(inFile: "OEBPS/Audio/b.mp3", at: 12)?.fragmentID == whole.fragmentID)
    }

    /// Storyteller writes `clipEnd` on every par, and its ~1 ms fillers must
    /// still be dropped: nothing about a stated end changes.
    @Test("clips with stated ends, fillers included, come out exactly as before")
    func statedEndsAreUntouched() throws {
        let rows = try SMILParser.parse(data: Data("""
            <smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><seq>
              <par><text src="../ch01.xhtml#a"/><audio src="../Audio/a.mp3" clipBegin="0s" clipEnd="2s"/></par>
              <par><text src="../ch01.xhtml#b"/><audio src="../Audio/a.mp3" clipBegin="2s" clipEnd="2.001s"/></par>
              <par><text src="../ch01.xhtml#c"/><audio src="../Audio/a.mp3" clipBegin="2.001s" clipEnd="5s"/></par>
            </seq></body></smil>
            """.utf8), overlayHref: Self.overlay)
        #expect(rows.allSatisfy { !$0.isOpenEnded })
        let timeline = SMILParser.timeline(from: rows, fileDurations: ["OEBPS/Audio/a.mp3": 60])
        #expect(timeline.entries.map(\.fragmentID) == ["a", "c"], "the filler is still dropped")
        #expect(timeline.entries.map(\.end) == [2, 5], "and no stated end moves for a file length")
    }
}
