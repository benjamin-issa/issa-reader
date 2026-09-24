import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaPlayback

/// The read-along on a book aligned word by word, which the CLI offers: each
/// sentence's words in a `text-range-small` seq that names the sentence, and a
/// sentence's holes beside it.
///
/// Parsed from markup by the parser itself, so the timeline under the
/// coordinator is the one the app would build, and played over the v3
/// fixture's own `track1.mp3`, which is all the player needs of it.
///
///      0  ch01-s0-w0              0–1
///      1  ch01-s0-w1              1–2
///      2  ch01-s1-w0              2–3
///      3  ch01-s1-w1              3–4
///      4  ch01-s2-w0              4–5
///      5  ch01-s2-w1              5–6
///      6  ch01-s2     after-hole  6–10
///      7  ch01-s3-w0              10–11
///      8  ch01-s3-w1              11–12
@MainActor
@Suite("The read-along on a word-granular book")
struct ReadalongWordGranularTests {
    static let markup = """
        <?xml version="1.0" encoding="utf-8"?>
        <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0" epub:prefix="storyteller: https://storyteller-platform.gitlab.io/storyteller/docs/vocabulary">
          <body>
            <seq id="ch01_overlay" epub:textref="../ch01.xhtml" epub:type="chapter">
              <seq id="ch01-s0" epub:type="text-range-small storyteller:matched" epub:textref="../ch01.xhtml#ch01-s0">
                <par id="ch01-s0-w0"><text src="../ch01.xhtml#ch01-s0-w0"/><audio src="../Audio/track1.mp3" clipBegin="0.000s" clipEnd="1.000s"/></par>
                <par id="ch01-s0-w1"><text src="../ch01.xhtml#ch01-s0-w1"/><audio src="../Audio/track1.mp3" clipBegin="1.000s" clipEnd="2.000s"/></par>
              </seq>
              <seq id="ch01-s1" epub:type="text-range-small storyteller:matched" epub:textref="../ch01.xhtml#ch01-s1">
                <par id="ch01-s1-w0"><text src="../ch01.xhtml#ch01-s1-w0"/><audio src="../Audio/track1.mp3" clipBegin="2.000s" clipEnd="3.000s"/></par>
                <par id="ch01-s1-w1"><text src="../ch01.xhtml#ch01-s1-w1"/><audio src="../Audio/track1.mp3" clipBegin="3.000s" clipEnd="4.000s"/></par>
              </seq>
              <seq id="ch01-s2" epub:type="text-range-small storyteller:matched" epub:textref="../ch01.xhtml#ch01-s2">
                <par id="ch01-s2-w0"><text src="../ch01.xhtml#ch01-s2-w0"/><audio src="../Audio/track1.mp3" clipBegin="4.000s" clipEnd="5.000s"/></par>
                <par id="ch01-s2-w1"><text src="../ch01.xhtml#ch01-s2-w1"/><audio src="../Audio/track1.mp3" clipBegin="5.000s" clipEnd="6.000s"/></par>
              </seq>
              <par id="ch01-s2-after0" epub:type="storyteller:audio-only">
                <text src="../ch01.xhtml#ch01-s2"/><audio src="../Audio/track1.mp3" clipBegin="6.000s" clipEnd="10.000s"/>
              </par>
              <seq id="ch01-s3" epub:type="text-range-small storyteller:matched" epub:textref="../ch01.xhtml#ch01-s3">
                <par id="ch01-s3-w0"><text src="../ch01.xhtml#ch01-s3-w0"/><audio src="../Audio/track1.mp3" clipBegin="10.000s" clipEnd="11.000s"/></par>
                <par id="ch01-s3-w1"><text src="../ch01.xhtml#ch01-s3-w1"/><audio src="../Audio/track1.mp3" clipBegin="11.000s" clipEnd="12.000s"/></par>
              </seq>
            </seq>
          </body>
        </smil>
        """

    static func timeline() throws -> SMILTimeline {
        SMILParser.timeline(from: try SMILParser.parse(
            data: Data(markup.utf8), overlayHref: "OEBPS/MediaOverlays/ch01.smil"))
    }

    /// The coordinator over the markup, with the clock and the end of the file
    /// taken away: every command here plays from where it lands, and neither
    /// may move the entry before the test looks at where it went.
    static func make() throws -> (ReadalongCoordinator, SMILTimeline, URL) {
        let timeline = try timeline()
        try #require(timeline.entries.map(\.fragmentID) == [
            "ch01-s0-w0", "ch01-s0-w1", "ch01-s1-w0", "ch01-s1-w1",
            "ch01-s2-w0", "ch01-s2-w1", "ch01-s2", "ch01-s3-w0", "ch01-s3-w1",
        ])
        let (subject, directory) = try ReadalongV3ShapesTests.make(timeline)
        subject.player.onTimeUpdate = nil
        subject.player.onFinishedFile = nil
        return (subject, timeline, directory)
    }

    /// A tap between two of ch01-s2's words names the sentence. Its only hole
    /// is after its words, and that hole was the one entry naming it, so the
    /// tap played four seconds of music and none of the sentence.
    @Test("a sentence tapped by its own fragment plays from its first word, not its after-hole")
    func seekToASentencePlaysItsWords() async throws {
        let (subject, timeline, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }

        await subject.seek(toFragment: "ch01-s2")
        #expect(subject.activeEntry == timeline.entries[4])
        #expect(subject.activeFragmentID == "ch01-s2-w0")
    }
}
