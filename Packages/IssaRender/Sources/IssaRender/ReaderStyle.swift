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

    /// Which face the page is set in.
    ///
    /// A choice rather than a family name, because two of the three options
    /// are not names the app knows in advance: a custom face comes from a file
    /// the reader supplied, and the publisher's comes from inside the book.
    public enum Typeface: Sendable, Hashable, Codable {
        /// Whatever the book itself asks for, where it ships a usable font.
        case publisher
        /// One of the faces the app ships.
        case bundled(String)
        /// A face the reader installed or imported.
        case custom(String)

        /// Encoded as one string so an unknown case decodes to a default
        /// rather than failing the whole settings blob — the same reason
        /// `ReaderStyle` decodes field by field.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            if raw == "publisher" { self = .publisher }
            else if raw.hasPrefix("custom:") { self = .custom(String(raw.dropFirst(7))) }
            else if raw.hasPrefix("bundled:") { self = .bundled(String(raw.dropFirst(8))) }
            else { self = .bundled(raw) }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(raw)
        }

        var raw: String {
            switch self {
            case .publisher: "publisher"
            case let .bundled(name): "bundled:\(name)"
            case let .custom(name): "custom:\(name)"
            }
        }

        /// The family name to ask CoreText for, where there is one in advance.
        public var familyName: String? {
            switch self {
            case .publisher: nil
            case let .bundled(name), let .custom(name): name
            }
        }
    }

    public var typeface: Typeface

    /// The family the current book embeds, once found.
    ///
    /// Not persisted: it belongs to the book, not to the reader's settings, and
    /// the reader may open a different book tomorrow. It *is* part of equality,
    /// so discovering it mid-open re-parses the chapter into the new face,
    /// which is exactly what should happen.
    public var publisherFamily: String?

    /// The face the app sets a page in when nothing else is chosen.
    public static let defaultFamily = "Newsreader"

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
        typeface: Typeface = .bundled(Self.defaultFamily),
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
        self.typeface = typeface
        publisherFamily = nil
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
        case typeface, fontFamily, fontSize, lineSpacing, theme, justified, pageMargin
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
        // `typeface` replaced `fontFamily`. A blob written before it still
        // names a family, and that family is what the reader chose — so it
        // becomes a bundled typeface rather than being reset to the default.
        if let stored = try? container.decodeIfPresent(Typeface.self, forKey: .typeface) {
            typeface = stored
        } else if let family = try? container.decodeIfPresent(String.self, forKey: .fontFamily) {
            typeface = .bundled(family)
        } else {
            typeface = fallback.typeface
        }
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
        // Belongs to the book being read, not to the settings blob.
        publisherFamily = nil
    }

    /// Written out by hand because `publisherFamily` must not be persisted:
    /// it is a property of the open book, and storing it would set the next
    /// book in the last one's face.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeface, forKey: .typeface)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(lineSpacing, forKey: .lineSpacing)
        try container.encode(theme, forKey: .theme)
        try container.encode(justified, forKey: .justified)
        try container.encode(pageMargin, forKey: .pageMargin)
        try container.encode(highlightGranularity, forKey: .highlightGranularity)
        try container.encode(followNarration, forKey: .followNarration)
        try container.encode(turnPagesMidSentence, forKey: .turnPagesMidSentence)
        try container.encode(tapToPlay, forKey: .tapToPlay)
        try container.encode(progressDisplay, forKey: .progressDisplay)
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
    /// The face this book is actually set in, once the choice is resolved.
    ///
    /// `nil` for `.publisher` until the book has been opened and its own font
    /// found — and permanently, for a book that ships none.
    public var resolvedFamily: String? {
        switch typeface {
        case .publisher: publisherFamily
        case let .bundled(name), let .custom(name): name
        }
    }

    public func bodyFont(weight: PlatformFont.Weight = .regular, italic: Bool = false, scale: CGFloat = 1) -> PlatformFont {
        let size = fontSize * scale
        // The chosen face, then the app's own, then the system's. A book that
        // ships no usable font must still be set in something deliberate:
        // falling straight through to the system face changes the look of the
        // page for a setting the reader did not touch.
        for name in [resolvedFamily, Self.defaultFamily].compactMap({ $0 }) {
            guard let face = PlatformFont(name: name, size: size) else { continue }
            return italic ? face.withItalicTrait() : face
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
