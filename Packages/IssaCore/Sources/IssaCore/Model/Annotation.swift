import Foundation

/// A bookmark or a highlight the reader made.
///
/// Storyteller stores positions and nothing else — no annotations endpoint
/// exists in 2.x or 3.x — so these live on the device. They are written with a
/// locator rather than a page number so they survive a font change, and with
/// the quoted text so they survive the publisher revising the chapter.
public struct Annotation: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case bookmark
        case highlight
        case note
    }

    /// The highlight colours the reader can pick from, named rather than stored
    /// as hex so a future theme can restate them without migrating data.
    public enum Tint: String, Codable, Sendable, CaseIterable {
        case tangerine, moss, slate, rose, plum

        public var title: String {
            switch self {
            case .tangerine: "Tangerine"
            case .moss: "Moss"
            case .slate: "Slate"
            case .rose: "Rose"
            case .plum: "Plum"
            }
        }
    }

    public var id: String
    public var bookUUID: String
    public var kind: Kind
    public var tint: Tint
    /// Where it is, in the same terms as a saved reading position.
    public var locator: ReadiumLocator
    /// The text that was marked, for the list and for re-anchoring.
    public var excerpt: String
    /// The reader's own words, for a note.
    public var note: String?
    public var chapterTitle: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        bookUUID: String,
        kind: Kind,
        tint: Tint = .tangerine,
        locator: ReadiumLocator,
        excerpt: String,
        note: String? = nil,
        chapterTitle: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
    ) {
        self.id = id
        self.bookUUID = bookUUID
        self.kind = kind
        self.tint = tint
        self.locator = locator
        self.excerpt = excerpt
        self.note = note
        self.chapterTitle = chapterTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Sorts a book's annotations into reading order rather than the order they
    /// happened to be made in, which is what a contents-style list needs.
    public static func readingOrder(_ a: Annotation, _ b: Annotation) -> Bool {
        let left = a.locator.locations?.totalProgression ?? a.locator.locations?.progression ?? 0
        let right = b.locator.locations?.totalProgression ?? b.locator.locations?.progression ?? 0
        if left != right { return left < right }
        return (a.locator.locations?.charOffset ?? 0) < (b.locator.locations?.charOffset ?? 0)
    }
}
