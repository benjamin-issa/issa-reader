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
        /// Character index into the rendered text of the resource.
        ///
        /// An Issa extension: the server stores the locator as opaque JSON, and
        /// other clients ignore keys they do not know. It is the tie-breaker
        /// when the same sentence appears twice in a chapter, and it survives a
        /// font change, which a page number does not.
        public var charOffset: Int?

        public init(
            fragments: [String]? = nil,
            progression: Double? = nil,
            position: Int? = nil,
            totalProgression: Double? = nil,
            cssSelector: String? = nil,
            partialCfi: String? = nil,
            domRange: DOMRange? = nil,
            charOffset: Int? = nil,
        ) {
            self.fragments = fragments
            self.progression = progression
            self.position = position
            self.totalProgression = totalProgression
            self.cssSelector = cssSelector
            self.partialCfi = partialCfi
            self.domRange = domRange
            self.charOffset = charOffset
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

    /// Whether `totalProgression` is a fraction of the **audio** rather than of
    /// the text.
    ///
    /// One field, two clocks. `ReaderModel` writes a text progression with
    /// `type: "application/xhtml+xml"`; `AppModel.audioLocator` writes an audio
    /// progression with the track's own type. Both have always written the type
    /// correctly — nothing was reading it, so each side helpfully interpreted
    /// the other's number on its own scale. That is how a reading position
    /// resumed an audiobook tens of minutes early, and how an audiobook
    /// position dropped the reader into the wrong chapter.
    ///
    /// Deliberately a property of the locator rather than a new field on the
    /// wire: the evidence is already there and already round-trips.
    var isAudioScaled: Bool { type.lowercased().hasPrefix("audio/") }

    /// Matches this locator's href against a publication's spine hrefs.
    ///
    /// The href a locator carries is not reliably the one the OPF spine uses.
    /// Storyteller's Readium manifest serves absolute, percent-encoded paths,
    /// the official client writes those back, and an EPUB's own spine hrefs are
    /// relative to the package document. Comparing the strings directly means a
    /// position written by any other client silently resolves to nothing and the
    /// reader opens at chapter one.
    func matchesHref(_ candidate: String) -> Bool {
        Self.normalizeHref(href) == Self.normalizeHref(candidate)
    }

    static func normalizeHref(_ href: String) -> String {
        // Query and fragment are addressing within the resource, not the
        // resource itself.
        var value = href
        if let hash = value.firstIndex(of: "#") { value = String(value[value.startIndex ..< hash]) }
        if let query = value.firstIndex(of: "?") { value = String(value[value.startIndex ..< query]) }
        value = value.removingPercentEncoding ?? value
        // Compare on the last two components: enough to tell `text/ch01.xhtml`
        // from `images/ch01.xhtml`, tolerant of differing package roots.
        let parts = value.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
        return parts.suffix(2).joined(separator: "/").lowercased()
    }
}
