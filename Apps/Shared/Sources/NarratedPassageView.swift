import IssaRender
import IssaUI
import SwiftUI

/// The sentence being read and the paragraph around it, set large enough to
/// follow from across a desk: the upright half of iPhone Duo's inner display
/// propped open like a laptop, above the player.
///
/// Not a page. The page stays where it was underneath, and this is only a view
/// of what the voice is on, so it never moves the reader's place.
struct NarratedPassageView: View {
    let model: ReaderModel

    var body: some View {
        let theme = model.style.theme
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            if !model.chapterTitle.isEmpty {
                Text(model.chapterTitle.uppercased())
                    .font(Typography.caption.weight(.semibold))
                    .kerning(1.6)
                    .foregroundStyle(theme.text.opacity(0.55))
            }
            if let passage = model.narratedPassage {
                Text(Self.attributed(passage, theme: theme))
                    .font(.system(size: 25, design: .serif))
                    .lineSpacing(13)
                    .minimumScaleFactor(0.6)
            } else {
                Text("Press play to hear this book read aloud.")
                    .font(.system(size: 25, design: .serif))
                    .foregroundStyle(theme.text.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.spacing48)
        .padding(.top, Metrics.spacing32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reader.narratedPassage")
    }

    /// The paragraph dimmed, with the sentence being read in full ink on the
    /// reader's highlight.
    static func attributed(_ passage: (text: String, sentence: NSRange), theme: ReaderTheme) -> AttributedString {
        var attributed = AttributedString(passage.text)
        attributed.foregroundColor = theme.text.opacity(0.55)
        if let range = Range(passage.sentence, in: passage.text),
           let lit = Range(range, in: attributed) {
            attributed[lit].foregroundColor = theme.text
            attributed[lit].backgroundColor = theme.accent.opacity(0.22)
        }
        return attributed
    }
}
