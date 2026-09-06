import Foundation
import IssaUI
import Testing

@testable import IssaRender

/// The app is already on TestFlight with readers who have set a font, a theme
/// and margins. `PlaybackSettings` decodes the stored blob and falls back to a
/// fresh `ReaderStyle()` on any failure — so a new field decoded the ordinary
/// way would throw on every existing blob and silently reset all of it.
@Suite("Reader preferences survive a new field")
struct ReaderStyleMigrationTests {
    /// A blob exactly as it was written before `progressDisplay` existed.
    let legacy = """
    {
      "fontFamily": "Newsreader",
      "fontSize": 22,
      "lineSpacing": "roomy",
      "theme": "night",
      "justified": true,
      "pageMargin": 32,
      "highlightGranularity": "word",
      "followNarration": false,
      "turnPagesMidSentence": true,
      "tapToPlay": false
    }
    """

    @Test("a blob saved before the new field still decodes, keeping every setting")
    func legacyBlobSurvives() throws {
        let style = try JSONDecoder().decode(ReaderStyle.self, from: Data(legacy.utf8))
        #expect(style.fontSize == 22)
        #expect(style.theme == .night)
        #expect(style.justified)
        #expect(style.pageMargin == 32)
        #expect(style.lineSpacing == .roomy)
        #expect(style.highlightGranularity == .word)
        #expect(!style.followNarration)
        #expect(style.turnPagesMidSentence)
        #expect(!style.tapToPlay)
        // And the new fields take their defaults rather than failing the decode.
        #expect(style.progressDisplay == .book)
        #expect(style.highlighters == [:])
    }

    @Test("an empty object decodes to the defaults rather than throwing")
    func emptyObject() throws {
        let style = try JSONDecoder().decode(ReaderStyle.self, from: Data("{}".utf8))
        #expect(style == ReaderStyle())
    }

    @Test("the new field round-trips when it is present")
    func roundTrip() throws {
        var style = ReaderStyle()
        style.progressDisplay = .chapterPage
        style.fontSize = 19
        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(ReaderStyle.self, from: data)
        #expect(decoded.progressDisplay == .chapterPage)
        #expect(decoded.fontSize == 19)
        #expect(decoded == style)
    }

    /// An unknown value must not throw either — a blob written by a newer build
    /// should degrade, not wipe the reader's settings.
    @Test("an unrecognised value falls back instead of failing the whole blob")
    func unknownValue() throws {
        let future = #"{"fontSize": 21, "progressDisplay": "somethingNew"}"#
        let style = try JSONDecoder().decode(ReaderStyle.self, from: Data(future.utf8))
        #expect(style.fontSize == 21)
        #expect(style.progressDisplay == .book)
    }

    // MARK: - A highlighter per page colour

    @Test("the highlighters round-trip, presets and mixed colours alike")
    func highlightersRoundTrip() throws {
        let tint = HighlightTint(red: 0.2, green: 0.45, blue: 0.8, alpha: 0.5)
        var style = ReaderStyle()
        style.highlighters = [.paper: .preset(.moss), .night: .custom(tint)]
        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(ReaderStyle.self, from: data)
        #expect(decoded.highlighters == style.highlighters)
        #expect(decoded == style)
        // Keyed by the page colour's own name, so the blob can be read — and
        // decoded one entry at a time, which is what the next test needs.
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let highlighters = object?["highlighters"] as? [String: Any]
        #expect(highlighters?.keys.sorted() == ["night", "paper"])
    }

    /// The whole point of decoding this field one page colour at a time: a
    /// preset name a newer build introduced must cost that page colour its
    /// highlighter, and nothing else in the reader's settings.
    @Test("one unreadable highlighter costs one page colour, not the blob")
    func oneBadHighlighter() throws {
        let blob = """
        {
          "fontSize": 23,
          "theme": "slate",
          "justified": true,
          "highlighters": {
            "paper": {"preset": "unicorn"},
            "night": {"preset": "sage"}
          }
        }
        """
        let style = try JSONDecoder().decode(ReaderStyle.self, from: Data(blob.utf8))
        #expect(style.highlighters == [.night: .preset(.sage)])
        #expect(style.fontSize == 23)
        #expect(style.theme == .slate)
        #expect(style.justified)
    }

    /// And a `highlighters` that is not an object at all must not reset the
    /// font, the theme and the margins on the way past.
    @Test("a highlighters field of the wrong shape decodes to none")
    func garbageHighlighters() throws {
        let blob = #"{"fontSize": 20, "highlighters": "garbage"}"#
        let style = try JSONDecoder().decode(ReaderStyle.self, from: Data(blob.utf8))
        #expect(style.highlighters == [:])
        #expect(style.fontSize == 20)
    }

    @Test("nothing chosen is written as nothing, so an untouched blob is unchanged")
    func emptyIsNotWritten() throws {
        let data = try JSONEncoder().encode(ReaderStyle())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["highlighters"] == nil)
    }

    // MARK: - Which colour the page paints

    @Test("the highlight follows the page colour in force")
    func highlightColourFollowsTheme() {
        var style = ReaderStyle()
        style.highlighters = [.paper: .preset(.plum), .night: .preset(.iris)]
        style.theme = .paper
        #expect(style.highlightColor == ReaderTheme.paper.highlightColor(for: .preset(.plum)))
        style.theme = .night
        #expect(style.highlightColor == ReaderTheme.night.highlightColor(for: .preset(.iris)))
        // Sepia was never given one, so it keeps its own default.
        style.theme = .sepia
        #expect(style.highlightColor == ReaderTheme.sepia.highlight)
    }

    @Test("a page colour with no highlighter of its own falls back to the theme's",
          arguments: ReaderTheme.allCases)
    func fallsBackToTheTheme(_ theme: ReaderTheme) {
        var style = ReaderStyle()
        style.theme = theme
        #expect(style.highlightColor == theme.highlight)
    }

    /// A book's own overrides are about type, not colour, so the highlighter is
    /// a global value that passes straight through both directions.
    @Test("a per-book override neither carries nor loses a highlighter")
    func overridesIgnoreHighlighters() {
        var global = ReaderStyle()
        global.highlighters = [.paper: .preset(.rose)]
        var edited = global
        edited.fontSize = 26
        let difference = global.difference(to: edited)
        #expect(difference.fontSize == 26)
        #expect(global.applying(difference).highlighters == [.paper: .preset(.rose)])
        #expect(global.applying(difference).fontSize == 26)
    }
}
