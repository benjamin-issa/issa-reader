import Foundation
import IssaEPUB

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Turns an EPUB chapter's XHTML into styled text, keeping every element id so
/// media-overlay fragments can later be located exactly.
///
/// This is deliberately a scoped subset of HTML and CSS rather than a browser.
/// It covers what reflowable trade fiction actually uses — block and inline
/// flow, headings, emphasis, lists, blockquotes, breaks — and reports anything
/// beyond that so the caller can route the chapter to a web view instead.
public struct HTMLContentParser: Sendable {
    /// `NSAttributedString` is immutable but predates `Sendable`, and this
    /// struct only ever holds a finished, never-mutated instance.
    public struct Result: @unchecked Sendable {
        public let text: NSAttributedString
        /// Fragment id to its character range in `text`. This is what makes
        /// highlighting a shape draw rather than a DOM query.
        public let fragmentRanges: [String: NSRange]
        /// Structure this parser could not represent faithfully.
        public let complexity: ChapterComplexity
    }

    private let style: ReaderStyle

    public init(style: ReaderStyle) {
        self.style = style
    }

    public func parse(xhtml data: Data, baseHref: String) throws -> Result {
        let sanitised = Self.substituteNamedEntities(in: data)
        let root = try EPUBXML.parse(sanitised)

        let output = NSMutableAttributedString()
        var ranges: [String: NSRange] = [:]
        var complexity = ChapterComplexity()

        let body = root.firstDescendant(named: "body") ?? root
        var context = Context(style: style)
        render(node: body, into: output, ranges: &ranges, complexity: &complexity, context: &context)

        // Trimming the ends shifts every recorded range, so they move with it;
        // an off-by-one here misplaces every highlight in the chapter.
        let originalLength = output.length
        let trimmed = Self.trimTrailingNewlines(output)
        let offset = Self.leadingTrimOffset(of: output)
        let adjusted = offset == 0 && trimmed.length == originalLength
            ? ranges
            : ranges.compactMapValues { range -> NSRange? in
                let location = range.location - offset
                guard location >= 0, location < trimmed.length else { return nil }
                return NSRange(location: location, length: min(range.length, trimmed.length - location))
            }
        return Result(text: trimmed, fragmentRanges: adjusted, complexity: complexity)
    }

    // MARK: - Rendering

    private struct Context {
        var style: ReaderStyle
        var bold = false
        var italic = false
        var sizeScale: CGFloat = 1
        var blockquoteDepth = 0
        var listDepth = 0
        var isPreformatted = false
        var alignment: NSTextAlignment?
    }

    private func render(
        node: EPUBXMLNode,
        into output: NSMutableAttributedString,
        ranges: inout [String: NSRange],
        complexity: inout ChapterComplexity,
        context: inout Context,
    ) {
        let start = output.length
        var child = context

        switch node.name.lowercased() {
        case "script", "style", "head", "title":
            return

        case "b", "strong":
            child.bold = true
        case "i", "em", "cite", "dfn":
            child.italic = true
        case "h1": child.bold = true; child.sizeScale = 1.9
        case "h2": child.bold = true; child.sizeScale = 1.6
        case "h3": child.bold = true; child.sizeScale = 1.35
        case "h4", "h5", "h6": child.bold = true; child.sizeScale = 1.15
        case "blockquote":
            child.blockquoteDepth += 1
        case "ul", "ol":
            child.listDepth += 1
        case "pre", "code":
            child.isPreformatted = true

        case "br":
            output.append(NSAttributedString(string: "\n", attributes: attributes(for: context)))
            return

        case "img", "image", "svg":
            // Images are recorded rather than drawn for now; a chapter that
            // leans on them is a candidate for the web-view path.
            complexity.imageCount += 1
            return

        case "table":
            complexity.hasTables = true
        case "video", "audio", "iframe", "object", "embed":
            complexity.hasEmbeddedMedia = true
        default:
            break
        }

        if node.name.lowercased() == "script" { complexity.hasScripting = true }

        // Text content of this element, before descending.
        if !node.text.isEmpty {
            let string = context.isPreformatted ? node.text : Self.collapseWhitespace(node.text)
            if !string.isEmpty {
                output.append(NSAttributedString(string: string, attributes: attributes(for: child)))
            }
        }

        for sub in node.children {
            render(node: sub, into: output, ranges: &ranges, complexity: &complexity, context: &child)
            // Text following a child element belongs to this element.
            if !sub.tail.isEmpty {
                let tail = context.isPreformatted ? sub.tail : Self.collapseWhitespace(sub.tail)
                if !tail.isEmpty {
                    output.append(NSAttributedString(string: tail, attributes: attributes(for: child)))
                }
            }
        }

        if Self.isBlock(node.name) {
            appendParagraphBreak(to: output, context: child)
        }

        // Record the range this element occupies, so a SMIL fragment id maps to
        // exact characters.
        //
        // The attribute is applied only where none is set yet. Children are
        // rendered first, so this keeps the innermost id — which is the one the
        // media overlay references. Overwriting blindly would let an outer
        // wrapper's id replace every sentence span inside it, and the highlight
        // would then cover a whole chapter instead of one sentence.
        if let id = node["id"], output.length > start {
            let range = NSRange(location: start, length: output.length - start)
            ranges[id] = range
            // Collect first, then apply: mutating an attributed string while
            // enumerating it is undefined and silently skips ranges.
            var unclaimed: [NSRange] = []
            output.enumerateAttribute(.issaFragmentID, in: range) { existing, subrange, _ in
                if existing == nil { unclaimed.append(subrange) }
            }
            for subrange in unclaimed {
                output.addAttribute(.issaFragmentID, value: id, range: subrange)
            }
        }
    }

    private func appendParagraphBreak(to output: NSMutableAttributedString, context: Context) {
        guard output.length > 0 else { return }
        let existing = (output.string as NSString)
        // Never stack more than one blank line, however deeply nested.
        if existing.hasSuffix("\n\n") { return }
        output.append(NSAttributedString(string: "\n", attributes: attributes(for: context)))
    }

    private func attributes(for context: Context) -> [NSAttributedString.Key: Any] {
        var font = context.style.bodyFont(italic: context.italic, scale: context.sizeScale)
        if context.bold { font = font.withBoldTrait() }

        let paragraph = NSMutableParagraphStyle()
        // Large type needs proportionally less leading; applying the body
        // multiple to a 1.9x heading leaves it floating in whitespace.
        let leadingScale = context.sizeScale > 1.2 ? 0.82 : 1.0
        paragraph.lineHeightMultiple = context.style.lineSpacing.multiple * leadingScale
        paragraph.alignment = context.alignment
            ?? (context.style.justified ? .justified : .natural)
        // Hyphenation matters far more in a justified column; without it,
        // justified text opens rivers of whitespace.
        paragraph.hyphenationFactor = context.style.justified ? 1.0 : 0.0
        paragraph.paragraphSpacing = context.style.fontSize * (context.sizeScale > 1.2 ? 0.55 : 0.30)
        let indent = CGFloat(context.blockquoteDepth + context.listDepth) * context.style.fontSize * 1.2
        paragraph.headIndent = indent
        paragraph.firstLineHeadIndent = indent

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: context.style.textColor,
            .paragraphStyle: paragraph,
        ]
        if context.blockquoteDepth > 0 {
            attributes[.issaBlockquoteDepth] = context.blockquoteDepth
        }
        return attributes
    }

    // MARK: - Text handling

    private static let blockElements: Set<String> = [
        "p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "li", "ul", "ol", "figure", "figcaption", "header",
        "footer", "main", "aside", "hr", "table", "tr", "dd", "dt", "dl",
    ]

    static func isBlock(_ name: String) -> Bool {
        blockElements.contains(name.lowercased())
    }

    /// HTML collapses runs of whitespace to a single space; preserving them
    /// verbatim produces visible gaps where the source was merely indented.
    ///
    /// Non-breaking spaces are deliberately exempt. `Character.isWhitespace` is
    /// true for U+00A0, so a naive collapse silently rewrites every `&nbsp;`
    /// into an ordinary space — losing exactly the line-breaking behaviour the
    /// author asked for, in places like "Chapter 1" or "10 km" where a break
    /// would read badly.
    static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace, !Self.nonCollapsing.contains(character) {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result
    }

    /// Whitespace that carries meaning and must survive collapsing.
    private static let nonCollapsing: Set<Character> = [
        "\u{00A0}", // no-break space
        "\u{202F}", // narrow no-break space
        "\u{2007}", // figure space
        "\u{2060}", // word joiner
    ]

    /// XHTML may reference HTML named entities that XML itself does not define,
    /// `&nbsp;` above all. XMLParser treats those as fatal, so they are rewritten
    /// to numeric references before parsing — otherwise perfectly ordinary books
    /// fail to open.
    static func substituteNamedEntities(in data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        guard text.contains("&") else { return data }
        for (name, code) in namedEntities {
            text = text.replacingOccurrences(of: "&\(name);", with: "&#\(code);")
        }
        return Data(text.utf8)
    }

    static let namedEntities: [String: Int] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "sect": 167,
        "copy": 169, "laquo": 171, "reg": 174, "deg": 176, "plusmn": 177,
        "para": 182, "middot": 183, "raquo": 187, "frac14": 188, "frac12": 189,
        "frac34": 190, "iquest": 191, "agrave": 224, "aacute": 225, "acirc": 226,
        "atilde": 227, "auml": 228, "aring": 229, "aelig": 230, "ccedil": 231,
        "egrave": 232, "eacute": 233, "ecirc": 234, "euml": 235, "igrave": 236,
        "iacute": 237, "icirc": 238, "iuml": 239, "ntilde": 241, "ograve": 242,
        "oacute": 243, "ocirc": 244, "otilde": 245, "ouml": 246, "oslash": 248,
        "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252, "yuml": 255,
        "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218,
        "ldquo": 8220, "rdquo": 8221, "bdquo": 8222, "dagger": 8224, "Dagger": 8225,
        "bull": 8226, "hellip": 8230, "prime": 8242, "Prime": 8243, "euro": 8364,
        "trade": 8482, "ensp": 8194, "emsp": 8195, "thinsp": 8201, "shy": 173,
    ]

    /// How many characters `trimTrailingNewlines` removes from the front.
    static func leadingTrimOffset(of text: NSAttributedString) -> Int {
        let string = text.string as NSString
        var begin = 0
        while begin < string.length {
            let character = string.character(at: begin)
            guard character == 10 || character == 32 || character == 9 || character == 13 else { break }
            begin += 1
        }
        return begin
    }

    /// Trims whitespace from both ends.
    ///
    /// Source markup routinely puts a newline between `<body>` and the first
    /// block, which would otherwise open every chapter on a stray space and
    /// shift every recorded fragment range by one.
    static func trimTrailingNewlines(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        func isTrimmable(_ character: unichar) -> Bool {
            character == 10 || character == 32 || character == 9 || character == 13
        }
        var end = string.length
        while end > 0, isTrimmable(string.character(at: end - 1)) { end -= 1 }
        var begin = 0
        while begin < end, isTrimmable(string.character(at: begin)) { begin += 1 }
        guard begin > 0 || end < string.length else { return text }
        return text.attributedSubstring(from: NSRange(location: begin, length: end - begin))
    }
}

/// What a chapter contains that the native renderer cannot represent faithfully.
///
/// The reader routes a chapter to a web view only when this says it must, so the
/// fast native path handles the overwhelming majority of pages and the slow path
/// exists for the tail. On tvOS there is no web view at all, so a complex
/// chapter simply renders linearised.
public struct ChapterComplexity: Sendable, Hashable {
    public var hasTables = false
    public var hasEmbeddedMedia = false
    public var hasScripting = false
    public var imageCount = 0

    public init() {}

    /// Images alone are common and harmless; structure the layout engine cannot
    /// express is what forces a fallback.
    public var requiresWebView: Bool {
        hasTables || hasEmbeddedMedia || hasScripting
    }
}
