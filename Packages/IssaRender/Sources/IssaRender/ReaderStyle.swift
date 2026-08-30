import CoreGraphics
import Foundation
import IssaUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Typography and layout the reader applies, matching the design's
/// "Reading & highlights" controls.
public struct ReaderStyle: Sendable, Hashable {
    public enum LineSpacing: String, CaseIterable, Sendable, Codable {
        case tight, normal, roomy

        /// Multiples of the font's natural line height. A serif reading face
        /// already carries generous internal leading, so these sit lower than a
        /// UI stack would use — 1.45 reads as airy, not comfortable.
        var multiple: CGFloat {
            switch self {
            case .tight: 1.05
            case .normal: 1.20
            case .roomy: 1.42
            }
        }
    }

    /// Granularity of the read-along highlight, from the design's Word /
    /// Sentence / Line control.
    public enum HighlightGranularity: String, CaseIterable, Sendable, Codable {
        case word, sentence, line
    }

    public var fontFamily: String
    public var fontSize: CGFloat
    public var lineSpacing: LineSpacing
    public var theme: ReaderTheme
    public var justified: Bool
    public var pageMargin: CGFloat
    public var highlightGranularity: HighlightGranularity
    /// Keep the narrated sentence on screen while audio plays.
    public var followNarration: Bool
    /// Allow a page to turn part-way through a sentence rather than waiting
    /// for it to finish.
    public var turnPagesMidSentence: Bool

    public init(
        fontFamily: String = "Newsreader",
        fontSize: CGFloat = 18,
        lineSpacing: LineSpacing = .normal,
        theme: ReaderTheme = .paper,
        justified: Bool = false,
        pageMargin: CGFloat = 24,
        highlightGranularity: HighlightGranularity = .sentence,
        followNarration: Bool = true,
        turnPagesMidSentence: Bool = false,
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.theme = theme
        self.justified = justified
        self.pageMargin = pageMargin
        self.highlightGranularity = highlightGranularity
        self.followNarration = followNarration
        self.turnPagesMidSentence = turnPagesMidSentence
    }

    /// Body font, falling back to the system serif when the bundled family is
    /// unavailable so early builds and previews still render.
    public func bodyFont(weight: PlatformFont.Weight = .regular, italic: Bool = false, scale: CGFloat = 1) -> PlatformFont {
        let size = fontSize * scale
        if let custom = PlatformFont(name: fontFamily, size: size) {
            return italic ? custom.withItalicTrait() : custom
        }
        let system = PlatformFont.systemFont(ofSize: size, weight: weight)
        return italic ? system.withItalicTrait() : system
    }

    public var textColor: PlatformColor { PlatformColor(theme.text) }
    public var backgroundColor: PlatformColor { PlatformColor(theme.background) }
}

extension PlatformFont {
    /// Adds an italic trait where the face has one, otherwise returns self.
    /// Never synthesises an oblique — a faked italic in a serif reading face
    /// looks visibly wrong.
    func withItalicTrait() -> PlatformFont {
        #if canImport(UIKit)
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(.traitItalic),
        ) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
        #elseif canImport(AppKit)
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
        #endif
    }

    func withBoldTrait() -> PlatformFont {
        #if canImport(UIKit)
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(.traitBold),
        ) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
        #elseif canImport(AppKit)
        let descriptor = fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
        #endif
    }
}
