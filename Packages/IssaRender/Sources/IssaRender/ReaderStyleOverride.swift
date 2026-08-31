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
    public var justified: Bool?

    public init(
        typeface: ReaderStyle.Typeface? = nil,
        fontSize: CGFloat? = nil,
        lineSpacing: ReaderStyle.LineSpacing? = nil,
        justified: Bool? = nil,
    ) {
        self.typeface = typeface
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.justified = justified
    }

    /// Whether this book has anything of its own left.
    ///
    /// An override that overrides nothing is deleted rather than stored, so
    /// "use my defaults" leaves no trace to go stale.
    public var isEmpty: Bool {
        typeface == nil && fontSize == nil && lineSpacing == nil && justified == nil
    }

    /// Which fields the reader has taken control of, for the sheet to show.
    public var count: Int {
        [typeface != nil, fontSize != nil, lineSpacing != nil, justified != nil]
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
        if let justified = override.justified { style.justified = justified }
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
            justified: other.justified == justified ? nil : other.justified,
        )
    }
}
