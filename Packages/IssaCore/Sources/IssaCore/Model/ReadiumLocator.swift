import Foundation

/// A position inside a publication, in the shape Storyteller stores and returns.
///
/// Verified against `applications/web/src/database/positions.ts` at tag `web-v2.14.21`:
/// the server persists this verbatim as JSON and compares stored vs incoming
/// locators with a deep equality check. That comparison is why this client always
/// authors its own locators rather than echoing one the server returned: an equal
/// timestamp paired with a structurally different locator is rejected with a 409.
public struct ReadiumLocator: Codable, Hashable, Sendable {
    /// Href of the resource this locator points into, as it appears in the
    /// publication manifest (e.g. `OEBPS/text/ch01.xhtml`).
    public var href: String
    /// Media type of the resource, e.g. `application/xhtml+xml`.
    public var type: String
    public var title: String?
    public var locations: Locations?
    public var text: Text?

    public struct Locations: Codable, Hashable, Sendable {
        /// Fragment identifiers within the resource. For a Storyteller readaloud
        /// this carries the media-overlay sentence id (`{chapterId}-s{n}`).
        public var fragments: [String]?
        /// Progress within the resource, 0...1.
        public var progression: Double?
        /// 1-based index into the publication's synthetic page list.
        public var position: Int?
        /// Progress through the whole publication, 0...1. This is what a UI
        /// should show as "percent complete".
        public var totalProgression: Double?
        public var cssSelector: String?
        public var partialCfi: String?
        public var domRange: DOMRange?

        public init(
            fragments: [String]? = nil,
            progression: Double? = nil,
            position: Int? = nil,
            totalProgression: Double? = nil,
            cssSelector: String? = nil,
            partialCfi: String? = nil,
            domRange: DOMRange? = nil,
        ) {
            self.fragments = fragments
            self.progression = progression
            self.position = position
            self.totalProgression = totalProgression
            self.cssSelector = cssSelector
            self.partialCfi = partialCfi
            self.domRange = domRange
        }
    }

    public struct DOMRange: Codable, Hashable, Sendable {
        public var start: Point
        public var end: Point?

        public struct Point: Codable, Hashable, Sendable {
            public var cssSelector: String
            public var textNodeIndex: Int
            public var charOffset: Int?

            public init(cssSelector: String, textNodeIndex: Int, charOffset: Int? = nil) {
                self.cssSelector = cssSelector
                self.textNodeIndex = textNodeIndex
                self.charOffset = charOffset
            }
        }

        public init(start: Point, end: Point? = nil) {
            self.start = start
            self.end = end
        }
    }

    /// Surrounding text, used to re-anchor a position if the resource changes.
    public struct Text: Codable, Hashable, Sendable {
        public var before: String?
        public var highlight: String?
        public var after: String?

        public init(before: String? = nil, highlight: String? = nil, after: String? = nil) {
            self.before = before
            self.highlight = highlight
            self.after = after
        }
    }

    public init(
        href: String,
        type: String,
        title: String? = nil,
        locations: Locations? = nil,
        text: Text? = nil,
    ) {
        self.href = href
        self.type = type
        self.title = title
        self.locations = locations
        self.text = text
    }
}

public extension ReadiumLocator {
    /// Book-level completion, 0...1, or `nil` when the server has not computed it.
    var totalProgression: Double? { locations?.totalProgression }

    /// The media-overlay sentence id this locator points at, when there is one.
    var sentenceID: String? { locations?.fragments?.first }
}
