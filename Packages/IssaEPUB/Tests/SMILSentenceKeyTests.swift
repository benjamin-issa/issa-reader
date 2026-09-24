import Foundation
import Testing

@testable import IssaEPUB

/// A narration stated as the SMIL a word-granular alignment writes, parsed
/// and built into a timeline by the parser itself.
///
/// The CLI's word mode nests each sentence's word pars in a `text-range-small`
/// seq whose `epub:textref` names the sentence; Storyteller 3 puts the
/// sentence's holes beside that seq, naming the sentence too. Every shape here
/// is one chapter, `OEBPS/ch01.xhtml`, read from `OEBPS/Audio/track1.mp3`.
enum WordGranularMarkup {
    static let chapter = "OEBPS/ch01.xhtml"

    static func timeline(_ body: String) throws -> SMILTimeline {
        SMILParser.timeline(from: try rows(body))
    }

    static func rows(_ body: String) throws -> [SMILParser.Row] {
        try SMILParser.parse(data: Data(smil(body).utf8), overlayHref: "OEBPS/MediaOverlays/ch01.smil")
    }

    /// `body` inside the chapter seq, in a document that declares the
    /// storyteller vocabulary as 3.x does.
    static func smil(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0" epub:prefix="storyteller: https://storyteller-platform.gitlab.io/storyteller/docs/vocabulary">
          <body>
            <seq id="ch01_overlay" epub:textref="../ch01.xhtml" epub:type="chapter">
        \(body)
            </seq>
          </body>
        </smil>
        """
    }

    /// A sentence's words, in the seq that names it.
    static func sentence(_ id: String, _ words: String...) -> String {
        """
        <seq id="\(id)" epub:type="text-range-small storyteller:matched" epub:textref="../ch01.xhtml#\(id)">
        \(words.joined(separator: "\n"))
        </seq>
        """
    }

    static func word(_ id: String, _ begin: Double, _ end: Double) -> String {
        """
        <par id="\(id)" epub:type="storyteller:matched">
          <text src="../ch01.xhtml#\(id)"/>
          <audio src="../Audio/track1.mp3" clipBegin="\(begin)s" clipEnd="\(end)s"/>
        </par>
        """
    }

    /// A hole: audio with no words, naming the sentence it hangs off.
    static func hole(_ sentence: String, _ begin: Double, _ end: Double) -> String {
        """
        <par id="\(sentence)-hole\(Int(begin))" epub:type="storyteller:audio-only">
          <text src="../ch01.xhtml#\(sentence)"/>
          <audio src="../Audio/track1.mp3" clipBegin="\(begin)s" clipEnd="\(end)s"/>
        </par>
        """
    }
}

/// A word-granular sentence's own fragment — what a tap between two of its
/// words, a selection, or the start of a page resolves — reaches the sentence.
///
/// Only its holes used to name it, first claim winning, so a sentence with a
/// hole only after its words resolved to that hole and played the music after
/// it, and a sentence with no holes resolved to nothing.
@Suite("A word-granular sentence resolves to its first entry")
struct SMILSentenceKeyTests {
    typealias Markup = WordGranularMarkup

    @Test("a word records the sentence it is a word of, and nothing else does")
    func sentenceIDs() throws {
        let entries = try SMILWordGranularV3Tests.timeline().entries
        #expect(entries.map(\.sentenceID) == [nil, "ch01-s0", "ch01-s0", nil, "ch01-s1", "ch01-s1"])
    }

    /// A pin: the before-hole already named the sentence, first.
    @Test("a sentence with a hole in front resolves to the hole")
    func beforeHoleWins() throws {
        let timeline = try SMILWordGranularV3Tests.timeline()
        #expect(timeline.entry(forFragment: "ch01-s0", inDocument: Markup.chapter) == timeline.entries[0])
        #expect(timeline.entry(forFragment: "ch01-s0") == timeline.entries[0])
    }

    ///      0  ch01-s0-w0              0–1
    ///      1  ch01-s0-w1              1–2
    ///      2  ch01-s0     after-hole  2–14
    ///      3  ch01-s1-w0              14–15
    ///      4  ch01-s1-w1              15–16
    @Test("a sentence with a hole only after its words resolves to its first word, not the hole")
    func afterHoleNeverWins() throws {
        let timeline = try Markup.timeline([
            Markup.sentence("ch01-s0", Markup.word("ch01-s0-w0", 0, 1), Markup.word("ch01-s0-w1", 1, 2)),
            Markup.hole("ch01-s0", 2, 14),
            Markup.sentence("ch01-s1", Markup.word("ch01-s1-w0", 14, 15), Markup.word("ch01-s1-w1", 15, 16)),
        ].joined(separator: "\n"))
        let entries = timeline.entries
        try #require(entries.map(\.fragmentID) == [
            "ch01-s0-w0", "ch01-s0-w1", "ch01-s0", "ch01-s1-w0", "ch01-s1-w1",
        ])
        #expect(timeline.entry(forFragment: "ch01-s0", inDocument: Markup.chapter) == entries[0])
        #expect(timeline.entry(forFragment: "ch01-s0") == entries[0], "by id alone as well")
        #expect(timeline.bookTime(forFragment: "ch01-s0", inDocument: Markup.chapter) == 0)
        // Its words and its hole are still each their own place.
        #expect(timeline.entry(forFragment: "ch01-s0-w1", inDocument: Markup.chapter) == entries[1])
    }

    @Test("a sentence with no holes resolves to its first word")
    func noHoles() throws {
        let timeline = try SMILWordGranularV3Tests.timeline()
        let entries = timeline.entries
        #expect(timeline.entry(forFragment: "ch01-s1", inDocument: Markup.chapter) == entries[4])
        #expect(timeline.entry(forFragment: "ch01-s1") == entries[4], "by id alone as well")
        #expect(timeline.bookTime(forFragment: "ch01-s1", inDocument: Markup.chapter)
            == entries[4].cumulativeEnd - entries[4].duration)
    }

    /// v2's CLI wrote the same seq with no storyteller vocabulary and no
    /// holes around it.
    @Test("a v2 CLI word-granular sentence resolves to its first word")
    func v2CLIMarkup() throws {
        let smil = """
            <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
              <body>
                <seq id="ch01_overlay" epub:textref="../ch01.xhtml" epub:type="chapter">
                  <seq id="s0" epub:type="text-range-small" epub:textref="../ch01.xhtml#s0">
                    <par id="s0-w0"><text src="../ch01.xhtml#s0-w0"/><audio src="../Audio/track1.mp3" clipBegin="0.000s" clipEnd="0.400s"/></par>
                    <par id="s0-w1"><text src="../ch01.xhtml#s0-w1"/><audio src="../Audio/track1.mp3" clipBegin="0.400s" clipEnd="0.900s"/></par>
                  </seq>
                </seq>
              </body>
            </smil>
            """
        let rows = try SMILParser.parse(data: Data(smil.utf8), overlayHref: "OEBPS/MediaOverlays/ch01.smil")
        #expect(rows.map(\.sentenceID) == ["s0", "s0"])
        let timeline = SMILParser.timeline(from: rows)
        #expect(timeline.entry(forFragment: "s0", inDocument: Markup.chapter)?.fragmentID == "s0-w0")
    }

    /// A block's seq names a paragraph, not a sentence, and the chapter's names
    /// a document: neither is anybody's sentence. Inside a block, a sentence
    /// seq still names its words'.
    @Test("a text-range-large seq and the chapter seq name no sentence")
    func onlyTheSentenceSeqCounts() throws {
        let rows = try Markup.rows("""
            <seq id="block0" epub:type="text-range-large" epub:textref="../ch01.xhtml#block0">
              <par id="ch01-s0"><text src="../ch01.xhtml#ch01-s0"/><audio src="../Audio/track1.mp3" clipBegin="0s" clipEnd="2s"/></par>
            \(Markup.sentence("ch01-s1", Markup.word("ch01-s1-w0", 2, 3)))
            </seq>
            """)
        #expect(rows.map(\.sentenceID) == [nil, "ch01-s1"])
        let timeline = SMILParser.timeline(from: rows)
        #expect(timeline.entry(forFragment: "block0", inDocument: Markup.chapter) == nil)
        #expect(timeline.entry(forFragment: "block0") == nil)
    }

    @Test("the unprefixed attribute spellings are read too")
    func unprefixedSpelling() throws {
        let rows = try Markup.rows("""
            <seq type="text-range-small" textref="../ch01.xhtml#ch01-s0">
            \(Markup.word("ch01-s0-w0", 0, 1))
            </seq>
            """)
        #expect(rows.map(\.sentenceID) == ["ch01-s0"])
    }

    /// Nil rather than a fragment nobody has: a textref with no `#` names a
    /// document, and a word the seq names itself is its own sentence already.
    @Test("a sentence seq naming no fragment, or naming its only word, records nothing")
    func degenerateSentenceSeqs() throws {
        let rows = try Markup.rows("""
            <seq epub:type="text-range-small" epub:textref="../ch01.xhtml">
            \(Markup.word("ch01-s0-w0", 0, 1))
            </seq>
            <seq epub:type="text-range-small" epub:textref="../ch01.xhtml#ch01-s1">
            \(Markup.word("ch01-s1", 1, 2))
            </seq>
            """)
        #expect(rows.map(\.sentenceID) == [nil, nil])
    }
}
