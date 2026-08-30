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
public struct ReaderStyle: Sendable, Hashable, Codable {
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
    /// What the always-visible progress readout shows.
    public enum ProgressDisplay: String, Codable, Sendable, CaseIterable {
        case book
        case chapterPage

        public var title: String {
            switch self {
            case .book: "Book percentage"
            case .chapterPage: "Page in chapter"
            }
        }
    }

    public var progressDisplay: ProgressDisplay

    /// Double-tapping a narrated sentence starts the audio there.
    ///
    /// Only ever consulted for a book that has narration. A single tap can no
    /// longer do this: it was indistinguishable from a page turn, and because
    /// it was tested first it made "tap left to go back" unreachable over any
    /// narrated text.
    public var tapToPlay: Bool

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
        tapToPlay: Bool = true,
        progressDisplay: ProgressDisplay = .book,
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
        self.tapToPlay = tapToPlay
        self.progressDisplay = progressDisplay
    }

    // Spelled out rather than synthesised, because the decoder below names them.
    enum CodingKeys: String, CodingKey {
        case fontFamily, fontSize, lineSpacing, theme, justified, pageMargin
        case highlightGranularity, followNarration, turnPagesMidSentence
        case tapToPlay, progressDisplay
    }

    /// Decoded field by field, with a default for anything absent.
    ///
    /// The synthesised decoder fails the whole blob when a new field is missing,
    /// and `PlaybackSettings` falls back to a fresh `ReaderStyle()` on failure —
    /// so adding a property the ordinary way would silently reset the font,
    /// theme, margins and every read-along toggle of everyone already running
    /// the app.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ReaderStyle()
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? fallback.fontFamily
        fontSize = try container.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? fallback.fontSize
        lineSpacing = Self.decodeCase(LineSpacing.self, from: container, key: .lineSpacing)
            ?? fallback.lineSpacing
        theme = Self.decodeCase(ReaderTheme.self, from: container, key: .theme) ?? fallback.theme
        justified = try container.decodeIfPresent(Bool.self, forKey: .justified) ?? fallback.justified
        pageMargin = try container.decodeIfPresent(CGFloat.self, forKey: .pageMargin) ?? fallback.pageMargin
        highlightGranularity = Self.decodeCase(
            HighlightGranularity.self, from: container, key: .highlightGranularity)
            ?? fallback.highlightGranularity
        followNarration = try container.decodeIfPresent(
            Bool.self, forKey: .followNarration) ?? fallback.followNarration
        turnPagesMidSentence = try container.decodeIfPresent(
            Bool.self, forKey: .turnPagesMidSentence) ?? fallback.turnPagesMidSentence
        tapToPlay = try container.decodeIfPresent(Bool.self, forKey: .tapToPlay) ?? fallback.tapToPlay
        progressDisplay = Self.decodeCase(
            ProgressDisplay.self, from: container, key: .progressDisplay) ?? fallback.progressDisplay
    }

    /// Reads a string-backed case, treating an unrecognised one as absent.
    ///
    /// `decodeIfPresent` still throws when the key is there but the value is
    /// not a known case — so a blob written by a newer build, or one that has
    /// been corrupted, would fail the whole decode and reset every preference.
    /// A value this build does not understand should cost that one setting,
    /// not all of them.
    private static func decodeCase<T: RawRepresentable & Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
    ) -> T? where T.RawValue == String {
        // `try?` flattens the doubly-optional decodeIfPresent result, so this is
        // already the unwrapped string.
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return T(rawValue: raw)
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
