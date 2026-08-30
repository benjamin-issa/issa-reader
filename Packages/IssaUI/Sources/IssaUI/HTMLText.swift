import Foundation
import SwiftUI

/// Renders the small fragments of HTML a book's metadata carries.
///
/// Deliberately not the EPUB parser. That one needs strict, single-root XHTML
/// and throws on the unclosed `<br>` and bare `&` that real publisher blurbs
/// are full of, and it bakes the reader's own typography into its output. This
/// is a forgiving scanner: it understands a handful of tags, ignores everything
/// else rather than failing, and never throws — a description that cannot be
/// parsed is still worth showing as text.
public enum HTMLText {
    /// Inline emphasis carried while scanning.
    private struct Style: Equatable {
        var bold = false
        var italic = false
        var link: URL?
    }

    /// Turns a fragment into styled text.
    ///
    /// Block tags become paragraph breaks, `<br>` a single newline, and runs of
    /// whitespace collapse the way a browser would — server descriptions are
    /// routinely pretty-printed with newlines that are not meant to be shown.
    public static func attributed(
        _ html: String,
        font: Font = Typography.body,
        color: Color = Palette.inkSecondary,
        linkColor: Color = Palette.tangerine,
    ) -> AttributedString {
        // Scanned into pieces first, assembled second. Trimming the space that
        // sits either side of a paragraph break needs to see both neighbours,
        // and markup is routinely pretty-printed with newlines between tags
        // that are not meant to appear.
        enum Piece {
            case text(String, Style)
            /// `hard` gaps come from block tags and merge to the larger of the
            /// two; soft ones come from `<br>` and add up, because two of them
            /// in a row is how most scraped blurbs separate paragraphs.
            case gap(Int, hard: Bool)
        }

        var pieces: [Piece] = []
        var styles: [Style] = [Style()]
        var buffer = ""

        func flush() {
            let text = collapse(decodeEntities(buffer))
            buffer = ""
            guard !text.isEmpty else { return }
            pieces.append(.text(text, styles.last ?? Style()))
        }

        var index = html.startIndex
        while index < html.endIndex {
            if html[index] == "<" {
                // A `<` with no matching `>` is literal text, not a broken tag.
                guard let close = html[index...].firstIndex(of: ">") else {
                    buffer.append(contentsOf: html[index...])
                    break
                }
                flush()
                var breaks = 0
                var hard = true
                apply(tag: String(html[html.index(after: index) ..< close]),
                      styles: &styles, breaks: &breaks, hard: &hard)
                if breaks > 0 { pieces.append(.gap(breaks, hard: hard)) }
                index = html.index(after: close)
            } else {
                buffer.append(html[index])
                index = html.index(after: index)
            }
        }
        flush()

        // Space against a block boundary is layout, not content — trim it on
        // both sides before assembling, which needs to see each gap's
        // neighbours and so cannot be done while scanning.
        for position in pieces.indices {
            guard case .gap = pieces[position] else { continue }
            if position > 0, case let .text(text, style) = pieces[position - 1] {
                var trimmed = text
                while trimmed.last == " " { trimmed.removeLast() }
                pieces[position - 1] = .text(trimmed, style)
            }
            if position + 1 < pieces.count, case let .text(text, style) = pieces[position + 1] {
                var trimmed = text
                while trimmed.first == " " { trimmed.removeFirst() }
                pieces[position + 1] = .text(trimmed, style)
            }
        }

        var out = AttributedString()
        var pendingGap = 0
        var wroteAnything = false
        for piece in pieces {
            switch piece {
            case let .gap(count, hard):
                guard wroteAnything else { break }
                pendingGap = hard ? max(pendingGap, count) : pendingGap + count
            case let .text(raw, style):
                var text = raw
                if !wroteAnything {
                    while text.first == " " { text.removeFirst() }
                }
                guard !text.isEmpty else { continue }
                if pendingGap > 0 {
                    out.append(AttributedString(String(repeating: "\n", count: min(pendingGap, 2))))
                    pendingGap = 0
                }
                var run = AttributedString(text)
                run.font = resolved(font, bold: style.bold, italic: style.italic)
                run.foregroundColor = style.link == nil ? color : linkColor
                if let link = style.link {
                    run.link = link
                    run.underlineStyle = .single
                }
                out.append(run)
                wroteAnything = true
            }
        }
        // A trailing space left by the last run is equally not content.
        while out.characters.last == " " { out.removeSubrange(out.index(beforeCharacter: out.endIndex) ..< out.endIndex) }
        return out
    }

    /// Plain text, for a widget or an accessibility label.
    public static func plain(_ html: String) -> String {
        String(attributed(html).characters)
    }

    private static func apply(
        tag raw: String, styles: inout [Style], breaks: inout Int, hard: inout Bool,
    ) {
        let closing = raw.hasPrefix("/")
        let body = closing ? String(raw.dropFirst()) : raw
        let name = body.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()

        switch name {
        case "b", "strong", "i", "em", "a":
            if closing {
                // Never pop the base style: stray closing tags are common.
                if styles.count > 1 { styles.removeLast() }
            } else {
                var style = styles.last ?? Style()
                switch name {
                case "b", "strong": style.bold = true
                case "i", "em": style.italic = true
                default: style.link = href(in: body)
                }
                // A self-closing tag opens nothing.
                if !body.hasSuffix("/") { styles.append(style) }
            }
        case "br":
            breaks = 1
            hard = false
        case "p", "div", "ul", "ol", "li", "h1", "h2", "h3", "h4", "blockquote":
            breaks = max(breaks, name == "li" ? 1 : 2)
        default:
            break  // Unknown tags are dropped, never rendered and never fatal.
        }
    }

    /// The destination of an anchor, if it is one worth following.
    ///
    /// Descriptions are scraped metadata, not content this app wrote, so the
    /// scheme is checked. `URL(string:)` happily builds `javascript:` and
    /// `data:` URLs, and a link rendered from one is handed straight to the
    /// system when tapped — a book blurb must not be able to do that.
    private static func href(in tag: String) -> URL? {
        guard let value = attribute("href", in: tag) else { return nil }
        // The value is markup too: `?a=1&amp;b=2` must not navigate to a
        // parameter literally named "amp;b".
        let decoded = decodeEntities(value).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: decoded),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// Reads one attribute out of a tag body.
    ///
    /// Matched as a whole attribute name, not a substring: searching for
    /// "href" anywhere found it inside `class="nohref"` and returned the
    /// wreckage instead of the real destination.
    static func attribute(_ name: String, in tag: String) -> String? {
        var rest = Substring(tag)
        while let found = rest.range(of: name, options: .caseInsensitive) {
            let before = found.lowerBound == rest.startIndex
                ? nil : rest[rest.index(before: found.lowerBound)]
            var after = rest[found.upperBound...].drop { $0.isWhitespace }
            // A real attribute is preceded by whitespace and followed by `=`.
            if before.map({ $0.isWhitespace }) ?? true, after.first == "=" {
                after = after.dropFirst().drop { $0.isWhitespace }
                guard let quote = after.first else { return nil }
                if quote == "\"" || quote == "'" {
                    let inner = after.dropFirst()
                    guard let end = inner.firstIndex(of: quote) else { return nil }
                    return String(inner[inner.startIndex ..< end])
                }
                return String(after.prefix { !$0.isWhitespace && $0 != ">" })
            }
            rest = rest[found.upperBound...]
        }
        return nil
    }

    private static func resolved(_ font: Font, bold: Bool, italic: Bool) -> Font {
        var result = font
        if bold { result = result.bold() }
        if italic { result = result.italic() }
        return result
    }

    /// Collapses runs of whitespace, the way a browser lays out HTML.
    private static func collapse(_ text: String) -> String {
        var out = ""
        var lastWasSpace = false
        for character in text {
            let isSpace = character.isWhitespace
            if isSpace {
                if !lastWasSpace { out.append(" ") }
            } else {
                out.append(character)
            }
            lastWasSpace = isSpace
        }
        return out
    }

    /// Decodes the entity forms that actually appear in book metadata.
    ///
    /// A bare `&` is left exactly as it is — descriptions contain them
    /// unescaped, and turning one into a parse failure loses the whole blurb.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&",
                  let end = text[index...].prefix(12).firstIndex(of: ";")
            else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            let name = String(text[text.index(after: index) ..< end])
            if let decoded = decode(entity: name) {
                out.append(decoded)
                index = text.index(after: end)
            } else {
                out.append(text[index])
                index = text.index(after: index)
            }
        }
        return out
    }

    private static func decode(entity name: String) -> Character? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            return value.flatMap(Unicode.Scalar.init).map(Character.init)
        }
        return named[name.lowercased()]
    }

    private static let named: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "mdash": "—", "ndash": "–", "hellip": "…",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "eacute": "é",
    ]
}
