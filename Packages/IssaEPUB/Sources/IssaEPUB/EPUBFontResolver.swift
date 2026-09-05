import Foundation

/// Finds the face a book asks to be set in.
///
/// **This is not a CSS engine, and should not become one.** The renderer
/// honours no stylesheets at all: `<style>` blocks are discarded before their
/// text is read, and no rule has ever reached a glyph. What this does is read
/// two things out of a book's CSS — the `@font-face` rules, and the family the
/// body is set in — and resolve them to one file. No cascade, no classes, no
/// specificity, no inheritance. A book with an elaborate stylesheet gets its
/// body face and nothing else.
///
/// That is the whole of "the publisher's font" as an option beside Newsreader
/// and Public Sans: one face for the running text, which is what a reader means
/// by it.
public enum EPUBFontResolver {
    /// A face a book ships, resolved to something that can be registered.
    public struct Face: Sendable, Hashable {
        /// The family as the stylesheet names it.
        public let family: String
        /// Where the file is inside the container.
        public let path: String
        /// The file's extension, lowercased.
        ///
        /// `path` carries no query string — see `fontFaces(in:relativeTo:)`,
        /// which strips it before resolving. The first fix for the bulletproof
        /// `url('fonts/Charis.otf?#iefix')` syntax stripped it *here* only, so
        /// `format` said "otf" while `path` still ended in `?`: the face was
        /// reported `.found` and then failed silently in `archive.read`, which
        /// is worse than the `.unreadableFormat("otf?")` it replaced.
        public var format: String {
            (path as NSString).pathExtension.lowercased()
        }
    }

    /// Why a book cannot be set in its own face.
    public enum Unavailable: Sendable, Hashable {
        /// No `@font-face` rule anywhere, which is most of Project Gutenberg.
        case noEmbeddedFont
        /// The font is there, in a format CoreText cannot read.
        case unreadableFormat(String)
        /// Obfuscated per the IDPF or Adobe scheme, and this app does not
        /// deobfuscate. The bytes on disk are not a font.
        case obfuscated
    }

    public enum Resolution: Sendable, Hashable {
        case found(Face)
        case unavailable(Unavailable)
    }

    /// The body face this book asks for.
    public static func resolve(in package: EPUBPackage) -> Resolution {
        let obfuscated = obfuscatedPaths(in: package)
        var faces: [String: Face] = [:]
        var bodyFamilies: [String] = []

        for sheet in stylesheets(in: package) {
            guard let css = try? package.archive.read(sheet),
                  let text = String(data: css, encoding: .utf8)
                      ?? String(data: css, encoding: .isoLatin1)
            else { continue }
            for face in fontFaces(in: text, relativeTo: sheet) {
                // First rule wins, matching how a browser resolves a repeated
                // family: later ones are alternates for weights we do not use.
                if faces[face.family.lowercased()] == nil {
                    faces[face.family.lowercased()] = face
                }
            }
            bodyFamilies.append(contentsOf: bodyFontFamilies(in: text))
        }

        guard !faces.isEmpty else { return .unavailable(.noEmbeddedFont) }

        // The body's own family first; failing that, the single face the book
        // embeds. A book that embeds exactly one font means it for the text.
        let candidates = bodyFamilies.compactMap { faces[$0.lowercased()] }
        let chosen = candidates.first ?? (faces.count == 1 ? faces.values.first : nil)
        guard let chosen else { return .unavailable(.noEmbeddedFont) }

        if obfuscated.contains(chosen.path) { return .unavailable(.obfuscated) }
        guard ["otf", "ttf", "ttc", "otc"].contains(chosen.format) else {
            return .unavailable(.unreadableFormat(chosen.format))
        }
        return .found(chosen)
    }

    // MARK: - Reading the CSS

    /// Every stylesheet the book declares, in manifest order.
    static func stylesheets(in package: EPUBPackage) -> [String] {
        package.manifest.values
            .filter { $0.mediaType == "text/css" || $0.href.lowercased().hasSuffix(".css") }
            .map(\.href)
            .sorted()
    }

    /// Everything before the first `?`. Written once here rather than inline,
    /// because the last inline copy lived on the wrong property.
    static func withoutQuery(_ url: String) -> String {
        url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
    }

    /// `@font-face { font-family: X; src: url(Y) }`, and nothing else.
    static func fontFaces(in css: String, relativeTo sheet: String) -> [Face] {
        var faces: [Face] = []
        for block in blocks(named: "@font-face", in: css) {
            guard let family = value(of: "font-family", in: block).map(unquote),
                  !family.isEmpty,
                  let source = firstURL(in: value(of: "src", in: block) ?? "")
            else { continue }
            faces.append(Face(
                family: family,
                // Query stripped before resolving, so `path` is the archive
                // path `archive.read` will be handed. `EPUBPackage.resolve`
                // strips a fragment but not a query, and publishers ship
                // `url('fonts/Charis.otf?#iefix')`.
                path: EPUBPackage.resolve(withoutQuery(source), relativeTo: sheet),
            ))
        }
        return faces
    }

    /// The families a `body` or `html` rule sets, most specific first.
    ///
    /// Only these two selectors. Honouring more would mean a cascade, and the
    /// renderer has nothing to apply one to.
    static func bodyFontFamilies(in css: String) -> [String] {
        var families: [String] = []
        for selector in ["body", "html"] {
            for block in blocks(named: selector, in: css) {
                guard let declared = value(of: "font-family", in: block) else { continue }
                families.append(contentsOf: declared
                    .split(separator: ",")
                    .map { unquote($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .filter { !$0.isEmpty })
            }
        }
        return families
    }

    /// Bodies of every rule whose selector list mentions `name` as a whole word.
    static func blocks(named name: String, in css: String) -> [String] {
        var blocks: [String] = []
        var selector = ""
        var depth = 0
        var body = ""
        for character in stripComments(css) {
            if character == "{" {
                depth += 1
                if depth == 1 { body = ""; continue }
            }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    if matches(name, selector: selector) { blocks.append(body) }
                    selector = ""
                    continue
                }
            }
            // A `;` at the top level ends a braceless at-rule — `@charset`,
            // `@import`, `@namespace`. Without this reset their text glues
            // itself onto the next rule's selector, and `matches` (an exact
            // equality test, deliberately) then rejects that rule outright.
            if depth == 0, character == ";" {
                selector = ""
                continue
            }
            if depth == 0 { selector.append(character) } else { body.append(character) }
        }
        return blocks
    }

    /// Removes `/* ... */` comments, which CSS permits anywhere. Left in, a
    /// comment ahead of a rule becomes part of its selector, and a comment
    /// inside a block corrupts the declaration it interrupts — either way a
    /// perfectly ordinary stylesheet loses its `@font-face` or `body` rule.
    static func stripComments(_ css: String) -> String {
        var result = ""
        result.reserveCapacity(css.count)
        var rest = Substring(css)
        while let open = rest.range(of: "/*") {
            result += rest[..<open.lowerBound]
            guard let close = rest.range(of: "*/", range: open.upperBound ..< rest.endIndex) else {
                // An unterminated comment swallows the rest of the sheet,
                // matching how a browser tokenises it.
                return result
            }
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }

    /// Whether a selector list targets `name` plainly — `body`, or `html, body`.
    ///
    /// `body.chapter` and `#body` do not count: they are the cascade, and the
    /// cascade is exactly what is not being implemented.
    static func matches(_ name: String, selector: String) -> Bool {
        selector
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains(name.lowercased())
    }

    /// A declaration's value, by property name.
    static func value(of property: String, in block: String) -> String? {
        for declaration in block.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard name == property.lowercased() else { continue }
            return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// The first `url(...)` in a `src` list.
    ///
    /// `src` may list several formats; the first is taken and then checked, so
    /// a book listing WOFF2 before OTF reports the format it named first. That
    /// is a deliberate simplification, and the reason `unreadableFormat` says
    /// which format it found.
    static func firstURL(in source: String) -> String? {
        guard let start = source.range(of: "url("),
              let end = source.range(of: ")", range: start.upperBound ..< source.endIndex)
        else { return nil }
        let inner = String(source[start.upperBound ..< end.lowerBound])
        let cleaned = unquote(inner.trimmingCharacters(in: .whitespacesAndNewlines))
        return cleaned.isEmpty ? nil : cleaned
    }

    static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote) && value.count > 1 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    // MARK: - Obfuscation

    /// Paths `META-INF/encryption.xml` says are obfuscated.
    ///
    /// EPUB permits a publisher to scramble the first 1040 bytes of a font so
    /// it cannot be lifted out of the book. Registering those bytes produces
    /// nothing; the reader is told the book's font cannot be used instead.
    static func obfuscatedPaths(in package: EPUBPackage) -> Set<String> {
        guard let data = try? package.archive.read("META-INF/encryption.xml"),
              let root = try? EPUBXML.parse(data)
        else { return [] }
        var paths: Set<String> = []
        for reference in root.descendants("CipherReference") {
            guard let uri = reference.attributes["URI"] else { continue }
            // Normalised, because `chosen.path` came through
            // `EPUBArchive.normalize` and this is compared against it. Adobe
            // InDesign and several Java toolchains write
            // `URI="./OEBPS/fonts/Body.otf"`, so the two spellings never
            // matched, the guard missed, and CoreText was handed 1040
            // XOR-scrambled bytes as a font — the book rendered in a broken
            // face instead of reporting `.obfuscated`.
            let decoded = uri.removingPercentEncoding ?? uri
            paths.insert(EPUBArchive.normalize(decoded))
        }
        return paths
    }
}
