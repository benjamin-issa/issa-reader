import CoreGraphics
import Foundation

/// One book's departure from the reading settings.
///
/// Sparse on purpose: every field is optional, and only the ones set are
/// applied. A book that overrides nothing but its face still follows a later
/// change to the global line spacing — which storing a whole resolved style
/// would silently freeze.
public struct ReaderStyleOverride: Sendable, Hashable, Codable {
    public var typeface: ReaderStyle.Typeface?
    public var fontSize: CGFloat?
    public var lineSpacing: ReaderStyle.LineSpacing?
    /// Unset means "whatever my reading settings say" — which may itself be
    /// "follow the book". Set means this book departs from that, in one of the
    /// three directions the global setting also offers.
    public var justification: ReaderStyle.Justification?

    public init(
        typeface: ReaderStyle.Typeface? = nil,
        fontSize: CGFloat? = nil,
        lineSpacing: ReaderStyle.LineSpacing? = nil,
        justification: ReaderStyle.Justification? = nil,
    ) {
        self.typeface = typeface
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.justification = justification
    }

    enum CodingKeys: String, CodingKey {
        case typeface, fontSize, lineSpacing, justified, justification
    }

    /// Decoded field by field, every field forgiving.
    ///
    /// Not the synthesised decoder, and the reason is one level up:
    /// `PlaybackSettings` decodes the whole `[String: ReaderStyleOverride]` map
    /// under a single `try?`, so one book carrying a value this build does not
    /// recognise — a typeface since removed, a case a newer build wrote — would
    /// throw out *every* book's typography. It is the rule
    /// `ReaderStyle.decodeCase` exists for, applied to the per-book blob that
    /// did not have it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        typeface = try? container.decodeIfPresent(ReaderStyle.Typeface.self, forKey: .typeface)
        fontSize = try? container.decodeIfPresent(CGFloat.self, forKey: .fontSize)
        lineSpacing = try? container.decodeIfPresent(
            ReaderStyle.LineSpacing.self, forKey: .lineSpacing)
        // `justification` replaced `justified`, and reads the old key the same
        // way `ReaderStyle` does: a book explicitly set to justified stays
        // justified, and one explicitly set ragged keeps that too — unlike the
        // global setting, a value here was always a deliberate act.
        if let stored = try? container.decodeIfPresent(
            ReaderStyle.Justification.self, forKey: .justification) {
            justification = stored
        } else if let legacy = try? container.decodeIfPresent(Bool.self, forKey: .justified) {
            justification = legacy ? .always : .never
        } else {
            justification = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(typeface, forKey: .typeface)
        try container.encodeIfPresent(fontSize, forKey: .fontSize)
        try container.encodeIfPresent(lineSpacing, forKey: .lineSpacing)
        try container.encodeIfPresent(justification, forKey: .justification)
    }

    /// Whether this book has anything of its own left.
    ///
    /// An override that overrides nothing is deleted rather than stored, so
    /// "use my defaults" leaves no trace to go stale.
    public var isEmpty: Bool {
        typeface == nil && fontSize == nil && lineSpacing == nil && justification == nil
    }

    /// Which fields the reader has taken control of, for the sheet to show.
    public var count: Int {
        [typeface != nil, fontSize != nil, lineSpacing != nil, justification != nil]
            .filter { $0 }.count
    }
}

public extension ReaderStyle {
    /// This style with one book's overrides laid over it.
    func applying(_ override: ReaderStyleOverride?) -> ReaderStyle {
        guard let override else { return self }
        var style = self
        if let typeface = override.typeface { style.typeface = typeface }
        if let fontSize = override.fontSize { style.fontSize = fontSize }
        if let lineSpacing = override.lineSpacing { style.lineSpacing = lineSpacing }
        if let justification = override.justification { style.justification = justification }
        return style
    }

    /// The override that would turn `self` into `other`, for the fields a book
    /// may set. Fields that already match are left unset, so a book only takes
    /// ownership of what the reader actually changed.
    func difference(to other: ReaderStyle) -> ReaderStyleOverride {
        ReaderStyleOverride(
            typeface: other.typeface == typeface ? nil : other.typeface,
            fontSize: other.fontSize == fontSize ? nil : other.fontSize,
            lineSpacing: other.lineSpacing == lineSpacing ? nil : other.lineSpacing,
            justification: other.justification == justification ? nil : other.justification,
        )
    }
}
