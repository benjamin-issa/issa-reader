import Foundation
import IssaRender
import Testing

@testable import IssaReader_iOS

/// What the television takes from the reader's settings, and what it insists on.
///
/// Five fields are the TV's — size, margin, follow-the-voice, tap-to-play and
/// what the progress readout counts — because a phone's answers to those make
/// an unreadable screen at ten feet. Everything else is still the reader's
/// choice, and none of it may travel back: the phone must not end up set in
/// 40 pt because someone opened a book on the television.
@Suite("The television's reading style")
struct TVReaderStyleTests {
    /// A settings blob that differs from the defaults in every field the TV
    /// overrides *and* every field it must respect, so nothing can pass by
    /// accidentally agreeing with a default.
    private static func chosen() -> ReaderStyle {
        var style = ReaderStyle()
        style.theme = .night
        style.typeface = .bundled("Newsreader")
        style.lineSpacing = .roomy
        style.justified = true
        style.fontSize = 22
        style.pageMargin = 48
        style.followNarration = false
        style.tapToPlay = true
        style.progressDisplay = .chapterPage
        style.highlightGranularity = .word
        style.turnPagesMidSentence = true
        return style
    }

    @Test("the television sets the size, the margin and the transport")
    func televisionOverrides() {
        let derived = TVReaderStyle.derive(from: Self.chosen(), publisherFamily: nil)
        #expect(derived.fontSize == 40)
        // The TV frames the page itself, so a margin inside it would only
        // narrow the measure that was just chosen.
        #expect(derived.pageMargin == 0)
        // The page is the transport: a remote has no scrubber, so the voice
        // turning the page is what keeps the reader with the story.
        #expect(derived.followNarration)
        // Nothing to tap: a Siri Remote moves focus, it does not point.
        #expect(!derived.tapToPlay)
        // "Page 4 of 12" is a chapter's number and means nothing across a room.
        #expect(derived.progressDisplay == .book)
    }

    @Test("the reader's own choices survive")
    func readersChoicesSurvive() {
        let style = Self.chosen()
        let derived = TVReaderStyle.derive(from: style, publisherFamily: nil)
        #expect(derived.theme == style.theme)
        #expect(derived.typeface == style.typeface)
        #expect(derived.lineSpacing == style.lineSpacing)
        #expect(derived.justified == style.justified)
        #expect(derived.highlightGranularity == style.highlightGranularity)
        #expect(derived.turnPagesMidSentence == style.turnPagesMidSentence)
    }

    /// The bug this replaced: the screen assigned `settings.readerStyle`
    /// wholesale, which carries no `publisherFamily` — so a book set in its own
    /// embedded face lost that face the moment anything else changed.
    @Test("the book's own face is carried across")
    func publisherFamilyCarries() {
        let derived = TVReaderStyle.derive(from: ReaderStyle(), publisherFamily: "Fanwood")
        #expect(derived.publisherFamily == "Fanwood")
        #expect(TVReaderStyle.derive(from: ReaderStyle(), publisherFamily: nil).publisherFamily == nil)
    }

    @Test("deriving leaves the reader's settings untouched")
    func inputIsUnchanged() {
        let style = Self.chosen()
        _ = TVReaderStyle.derive(from: style, publisherFamily: "Fanwood")
        #expect(style == Self.chosen())
    }

    /// Deriving twice must give the same answer as deriving once — the screen
    /// re-derives on every settings change, and a style that drifted would
    /// re-parse the chapter each time for nothing.
    @Test("deriving is idempotent")
    func idempotent() {
        let once = TVReaderStyle.derive(from: Self.chosen(), publisherFamily: "Fanwood")
        let twice = TVReaderStyle.derive(from: once, publisherFamily: "Fanwood")
        #expect(once == twice)
    }
}
