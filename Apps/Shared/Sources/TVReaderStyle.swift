import CoreGraphics
import IssaRender

/// The reader's own settings, re-cut for a screen ten feet away.
///
/// A television is not a small phone: what the reader chose on their phone —
/// 18 pt type, a margin, tap-to-play, "leave the page where I put it" — would
/// make an unreadable screen here. So five fields are the television's to
/// decide and the rest are the reader's, and the result is never written back
/// to `PlaybackSettings`: the phone must not inherit 40 pt type because someone
/// opened a book on the TV.
///
/// In `Apps/Shared` rather than beside `TVReadalongView` because the tvOS
/// target has no test bundle; this compiles into iOS as well, and
/// `IssaSharedTests` runs there.
enum TVReaderStyle {
    /// Reading size on a television.
    ///
    /// Apple's own ten-foot ramp puts body text at 29 pt; a book being *read*
    /// across a room needs more, and 40 pt with a 32 em measure gives a line of
    /// roughly 58–70 characters, which is what a printed page uses.
    static let fontSize: CGFloat = 40

    /// The reader's style as the television needs it.
    ///
    /// - Parameters:
    ///   - style: whatever the reader chose, from `PlaybackSettings`.
    ///   - publisherFamily: the face this book embeds, once the model has found
    ///     it. Carried across because it is a property of the *book* and not of
    ///     the settings — assigning `settings.readerStyle` wholesale was the
    ///     bug that dropped it, so a book set in its own face lost that face
    ///     the moment the TV changed anything else.
    static func derive(from style: ReaderStyle, publisherFamily: String?) -> ReaderStyle {
        var derived = style
        derived.fontSize = fontSize
        // The TV frames the page itself — `TVPageMetrics` puts the column in a
        // title-safe band with a running header above it — so a second margin
        // inside the page would only narrow the measure that was just chosen.
        derived.pageMargin = 0
        // The page is the transport here: there is no scrubber on a remote, so
        // the voice turning the page is the only thing that keeps the reader
        // with the story.
        derived.followNarration = true
        // Nothing to tap. A Siri Remote's touch surface moves focus; it does
        // not point at a sentence.
        derived.tapToPlay = false
        // "Page 4 of 12" is a chapter's number and means nothing across a room;
        // the footer says how far through the *book* the reader is, which is
        // also what the timeline draws.
        derived.progressDisplay = .book
        derived.publisherFamily = publisherFamily
        return derived
    }
}
