import Foundation
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
        // And the new field takes its default rather than failing the decode.
        #expect(style.progressDisplay == .book)
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
}
