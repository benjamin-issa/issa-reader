import Foundation

/// Finds the face a book asks to be set in.
///
/// Two questions, both answered out of the book's own CSS: which files it
/// embeds, and which family its running text is set in. The cascade itself
/// lives in `EPUBStyleSheet`; this is only about fonts.
///
/// That is the whole of "the publisher's font" as an option beside Newsreader
/// and Public Sans: one family for the running text, which is what a reader
/// means by it — but *every member* of that family, which is what makes a word
/// in italic look italic. A family registered with only its upright member is a
/// book with no emphasis in it, and one registered with only its italic member
/// is a book entirely in italic; both have happened here.
public enum EPUBFontResolver {
    /// A face a book ships, resolved to something that can be registered.
    public struct Face: Sendable, Hashable {
        /// The family as the stylesheet names it.
        public let family: String
        /// Where the file is inside the container.
        public let path: String
        /// Which member of the family this file is, as the rule declares it.
        ///
        /// A stylesheet lists one `@font-face` per member, and nothing but
        /// these two descriptors distinguishes them. Reading them is what lets
        /// the *upright* member be the one the page is set in: taking the first
        /// rule instead set one real book entirely in italic, because that is
        /// the order its publisher happened to write them in.
        public var isItalic = false
        public var isBold = false

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
        let embedded = members(in: package)
        guard !embedded.isEmpty else { return .unavailable(.noEmbeddedFont) }

        // The body's own family first; failing that, the single family the book
        // embeds. A book that embeds exactly one family means it for the text.
        let candidates = bodyFamilies(in: package).compactMap { embedded[$0.lowercased()] }
        let chosen = candidates.first ?? (embedded.count == 1 ? embedded.values.first : nil)
        guard let members = chosen, let representative = upright(among: members) else {
            return .unavailable(.noEmbeddedFont)
        }

        if obfuscated.contains(representative.path) { return .unavailable(.obfuscated) }
        guard ["otf", "ttf", "ttc", "otc"].contains(representative.format) else {
            return .unavailable(.unreadableFormat(representative.format))
        }
        return .found(representative)
    }

    /// Every face of one family the book embeds, in declaration order.
    ///
    /// What `resolvePublisherFont` registers. The upright regular is the face
    /// the page is set in; the others are what CoreText needs in order to have
    /// an italic to resolve to when a word asks for one — it is never
    /// synthesised, so a missing member is a missing italic.
    public static func members(of family: String, in package: EPUBPackage) -> [Face] {
        let obfuscated = obfuscatedPaths(in: package)
        return (members(in: package)[family.lowercased()] ?? [])
            .filter { ["otf", "ttf", "ttc", "otc"].contains($0.format) }
            .filter { !obfuscated.contains($0.path) }
    }

    /// Every embedded face, grouped by family.
    static func members(in package: EPUBPackage) -> [String: [Face]] {
        var faces: [String: [Face]] = [:]
        for sheet in stylesheets(in: package) {
            guard let text = css(at: sheet, in: package) else { continue }
            for face in fontFaces(in: text, relativeTo: sheet) {
                faces[face.family.lowercased(), default: []].append(face)
            }
        }
        return faces
    }

    /// The upright, regular member of a family, or the first there is.
    ///
    /// Falling back to the first matters: a book may embed only an italic, and
    /// setting the page in it is still better than ignoring the book's face —
    /// but it is a last resort, not the default it used to be.
    static func upright(among members: [Face]) -> Face? {
        members.first { !$0.isItalic && !$0.isBold } ?? members.first
    }

    static func css(at href: String, in package: EPUBPackage) -> String? {
        guard let data = try? package.archive.read(href) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Reading the CSS

    /// Every stylesheet the book declares, in manifest order.
    ///
    /// Public because the renderer reads the same list for the same book: this
    /// answers "which files", and `EPUBStyleSheet` answers what is in them.
    public static func stylesheets(in package: EPUBPackage) -> [String] {
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
                isItalic: (value(of: "font-style", in: block) ?? "").contains("italic")
                    || (value(of: "font-style", in: block) ?? "").contains("oblique"),
                isBold: EPUBStyleSheet.isBold(
                    (value(of: "font-weight", in: block) ?? "").trimmingCharacters(
                        in: .whitespacesAndNewlines).lowercased()) ?? false,
            ))
        }
        return faces
    }

    /// The families this book's running text is set in, most likely first.
    ///
    /// A bare `body` or `html` rule is the easy case and comes first. Failing
    /// that, the book's own `<body>` element is read — its class and its id —
    /// and the cascade asked what that element is set in. That second route is
    /// not exotic: an InDesign export writes `<body class="class-1">` against
    /// `.class-1 {font-family: AGaramondPro}` and never mentions `body` at all,
    /// so before it, a book that plainly embeds and names a face reported that
    /// it had none.
    static func bodyFamilies(in package: EPUBPackage) -> [String] {
        var families: [String] = []
        var sheet = EPUBStyleSheet()
        for href in stylesheets(in: package) {
            guard let text = css(at: href, in: package) else { continue }
            families.append(contentsOf: bodyFontFamilies(in: text))
            sheet.add(css: text)
        }
        guard !sheet.isEmpty else { return families }
        // The first document that has a <body> with anything on it. They are
        // all set the same way, and reading one is enough.
        for item in package.spine.prefix(3) {
            guard let data = try? package.archive.read(item.href),
                  let html = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .isoLatin1),
                  let body = bodyAttributes(in: html)
            else { continue }
            let asked = sheet.declarations(
                tag: "body", classes: body["class"], identifier: body["id"],
                inlineStyle: body["style"])
            if let declared = asked.families {
                families.append(contentsOf: declared)
                break
            }
        }
        return families
    }

    /// The attributes on a document's `<body>` open tag.
    ///
    /// Scanned rather than parsed, and deliberately: an XHTML chapter routinely
    /// names HTML entities that XML does not define, which fails a strict parse
    /// outright — the renderer rewrites them first, and it would be a poor
    /// trade to move that whole table here so that a *font* heuristic can read
    /// two attributes off one tag. The tag is the first `<body` in the file.
    static func bodyAttributes(in html: String) -> [String: String]? {
        guard let start = html.range(of: "<body", options: .caseInsensitive),
              let end = html[start.upperBound...].firstIndex(of: ">")
        else { return nil }
        var attributes: [String: String] = [:]
        let tag = html[start.upperBound ..< end]
        var rest = Substring(tag)
        while let equals = rest.firstIndex(of: "=") {
            let name = rest[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = rest[rest.index(after: equals)...]
                .drop(while: { $0 == " " || $0 == "\n" || $0 == "\t" })
            guard let quote = value.first, quote == "\"" || quote == "'" else { break }
            value = value.dropFirst()
            guard let closing = value.firstIndex(of: quote) else { break }
            if !name.isEmpty, !name.contains(" ") { attributes[name] = String(value[..<closing]) }
            rest = value[value.index(after: closing)...]
        }
        return attributes.isEmpty ? nil : attributes
    }

    /// The families a `body` or `html` rule sets, most specific first.
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
