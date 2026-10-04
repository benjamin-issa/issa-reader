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

    @Test("a blob this build writes is still readable by the build before it")
    func aBlobThisBuildWritesIsReadableByTheBuildBeforeIt() throws {
        // A reader who moves back a build must not silently lose their
        // justification: the old build reads only `justified`, so this one
        // keeps writing it. `.always` is the only case that build can express.
        func legacyBool(of justification: ReaderStyle.Justification) throws -> Bool? {
            var style = ReaderStyle()
            style.justification = justification
            let data = try JSONEncoder().encode(style)
            let blob = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return blob["justified"] as? Bool
        }
        #expect(try legacyBool(of: .always) == true)
        #expect(try legacyBool(of: .never) == false)
        #expect(try legacyBool(of: .followBook) == false)

        // And the new key is still there, so this build round-trips exactly.
        var style = ReaderStyle()
        style.justification = .never
        let restored = try JSONDecoder().decode(
            ReaderStyle.self, from: JSONEncoder().encode(style))
        #expect(restored.justification == .never)
    }

    @Test("a blob saved before the new field still decodes, keeping every setting")
    func legacyBlobSurvives() throws {
        let style = try JSONDecoder().decode(ReaderStyle.self, from: Data(legacy.utf8))
        #expect(style.fontSize == 22)
        #expect(style.theme == .night)
        #expect(style.justification == .always)
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

    /// Five fields read with a bare `try`, so one value of the wrong type threw
    /// the whole blob away and `PlaybackSettings` reset every preference.
    @Test("a field of the wrong type costs that field, not the blob", arguments: [
        ("fontSize", #""18""#),
        ("pageMargin", #""wide""#),
        ("followNarration", #""yes""#),
        ("turnPagesMidSentence", #""no""#),
        ("tapToPlay", "{}"),
    ])
    func wrongTypeIsForgiven(_ key: String, _ damaged: String) throws {
        // Every other field set away from its default, so a reset shows.
        var fields = [
            #""theme": "night""#, #""lineSpacing": "roomy""#, #""fontSize": 22"#,
            #""pageMargin": 32"#, #""followNarration": false"#,
            #""turnPagesMidSentence": true"#, #""tapToPlay": false"#,
        ].filter { !$0.hasPrefix("\"\(key)\"") }
        fields.append("\"\(key)\": \(damaged)")
        let blob = "{" + fields.joined(separator: ", ") + "}"
        let style = try JSONDecoder().decode(ReaderStyle.self, from: Data(blob.utf8))
        #expect(style.theme == .night)
        #expect(style.lineSpacing == .roomy)
        let fallback = ReaderStyle()
        #expect(style.fontSize == (key == "fontSize" ? fallback.fontSize : 22))
        #expect(style.pageMargin == (key == "pageMargin" ? fallback.pageMargin : 32))
        #expect(style.followNarration == (key == "followNarration" ? fallback.followNarration : false))
        #expect(style.turnPagesMidSentence
            == (key == "turnPagesMidSentence" ? fallback.turnPagesMidSentence : true))
        #expect(style.tapToPlay == (key == "tapToPlay" ? fallback.tapToPlay : false))
    }

    /// Nothing downstream bounds these: the page lays out at whatever size it
    /// is given, and the Text size stepper's label does `Int(size)`, which
    /// traps on anything past `Int.max`.
    @Test("an absurd size or margin is brought into range")
    func lengthsAreClamped() throws {
        let huge = try JSONDecoder().decode(
            ReaderStyle.self, from: Data(#"{"fontSize": 1e300, "pageMargin": 1e300}"#.utf8))
        #expect(huge.fontSize == ReaderStyle.fontSizeRange.upperBound)
        #expect(huge.pageMargin == ReaderStyle.pageMarginRange.upperBound)
        let tiny = try JSONDecoder().decode(
            ReaderStyle.self, from: Data(#"{"fontSize": -4, "pageMargin": -50}"#.utf8))
        #expect(tiny.fontSize == ReaderStyle.fontSizeRange.lowerBound)
        #expect(tiny.pageMargin == 0)
        // Every size the app can set is inside the range and left exactly.
        for size: CGFloat in [12, 18, 32, 40] {
            #expect(ReaderStyle.clampedLength(size, to: ReaderStyle.fontSizeRange) == size)
        }
        #expect(ReaderStyle.clampedLength(.infinity, to: ReaderStyle.fontSizeRange) == nil)
        #expect(ReaderStyle.clampedLength(.nan, to: ReaderStyle.fontSizeRange) == nil)
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
        #expect(style.justification == .always)
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
