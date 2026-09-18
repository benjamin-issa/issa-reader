import Foundation

/// The part of a book's CSS a reading app can honour, and no more.
///
/// **This is not a browser, and it must not become one.** It reads simple rules
/// off a stylesheet and answers one question: for this element, what did the
/// book ask for? Everything it cannot answer faithfully it declines to answer at
/// all, which is the only way a subset stays honest.
///
/// It exists because emphasis in a real trade ebook is very often not `<em>`.
/// *The Nudge* — the book that prompted this — marks every italic passage as
/// `<p class="class_s5T-0">` against `.class_s5T-0 {font-style: italic}`, and a
/// renderer that reads no CSS renders the whole conversation upright. So do the
/// first-line indent and the justification that make a page look like a book:
/// they are one `text-indent` and one `text-align` on `body`'s own class.
///
/// ### What it supports
///
/// Selectors: `tag`, `.class`, `tag.class`, `#id`, `*`, and comma-separated
/// lists of those. A descendant combinator, an attribute selector, a
/// pseudo-class or a media query is **skipped**, not approximated — a rule
/// half-applied is worse than a rule ignored, because the reader cannot see
/// which half.
///
/// Properties: the six in `Declarations`. The cascade is specificity then source
/// order, and an element's own `style=` attribute beats all of it.
///
/// ### What it will never support, and why
///
/// - **`color`** — the page colour belongs to the reader. This book sets
///   `#0000fe` on its links; on the night theme that is invisible.
/// - **`text-transform`**, **`display: none`**, **`content:`** — all three
///   change *which characters* are rendered. Every SMIL fragment range, every
///   Ask passage offset and every saved highlight is measured in those
///   characters, so a stylesheet that could move them would make the read-along
///   highlight and the reader's own notes land in the wrong place. Attributes
///   only; never text.
public struct EPUBStyleSheet: Sendable, Equatable {
    /// What a book asked for, where it asked for anything.
    ///
    /// Every field optional and inheritance left to the caller: the renderer
    /// already threads a context down the element tree, and that context *is* an
    /// inheritance chain. All six of these inherit in CSS, so folding a
    /// non-`nil` value into the child context is the whole of the rule.
    public struct Declarations: Sendable, Equatable {
        public var italic: Bool?
        public var bold: Bool?
        public var alignment: Alignment?
        /// A first-line indent, as a fraction of the column width or a multiple
        /// of the font size; see `Length`.
        public var textIndent: Length?
        /// A multiplier on the inherited size. Absolute units are deliberately
        /// dropped — see `Length.scale(relativeTo:)`.
        public var fontScale: Double?
        public var underlined: Bool?
        /// Families in declaration order, unquoted. Read by `EPUBFontResolver`,
        /// not by the renderer, which is handed one resolved face.
        public var families: [String]?

        public init() {}

        /// Folds `other` on top of self, later and more specific winning.
        mutating func merge(_ other: Declarations) {
            italic = other.italic ?? italic
            bold = other.bold ?? bold
            alignment = other.alignment ?? alignment
            textIndent = other.textIndent ?? textIndent
            fontScale = other.fontScale ?? fontScale
            underlined = other.underlined ?? underlined
            families = other.families ?? families
        }

        public var isEmpty: Bool { self == Declarations() }
    }

    public enum Alignment: String, Sendable, Equatable {
        case left, right, center, justify
    }

    /// A CSS length this reader can resolve without a layout engine.
    ///
    /// Percentages resolve against the column, `em`/`rem` against the text size.
    /// Absolute units are not a case, because honouring `font-size: 11pt` — what
    /// InDesign exports — would pin the page to the publisher's size and
    /// silently disable the reader's own Text size control. A book may say how
    /// much bigger; it may not say how big.
    public enum Length: Sendable, Equatable {
        case fraction(Double)
        case ems(Double)

        public func points(columnWidth: CGFloat, fontSize: CGFloat) -> CGFloat {
            switch self {
            case let .fraction(value): columnWidth * CGFloat(value)
            case let .ems(value): fontSize * CGFloat(value)
            }
        }
    }

    /// One parsed rule. `order` is where it appeared across every sheet, which
    /// is the tie-break when two selectors are equally specific.
    struct Rule: Sendable, Equatable {
        let selector: Selector
        let declarations: Declarations
        let order: Int
    }

    /// The shapes of selector this reader will match.
    ///
    /// Anything outside this list never becomes a `Selector`, so it can never
    /// match — which is the intended behaviour, not a gap.
    struct Selector: Sendable, Equatable {
        var tag: String?
        var klass: String?
        var identifier: String?

        /// CSS specificity, flattened to one comparable number. Ids outrank
        /// classes outrank tags, and nothing here can reach the next decade.
        var specificity: Int {
            (identifier == nil ? 0 : 100) + (klass == nil ? 0 : 10) + (tag == nil ? 0 : 1)
        }

        func matches(tag name: String, classes: Set<String>, identifier id: String?) -> Bool {
            if let tag, tag != name { return false }
            if let klass, !classes.contains(klass) { return false }
            if let identifier, identifier != id { return false }
            return true
        }
    }

    private var rules: [Rule] = []

    public init() {}

    /// Reads one stylesheet, appending to what is already here.
    ///
    /// Order matters and is the caller's to get right: sheets are added in the
    /// order the *document* links them, because that is what CSS breaks ties by.
    public mutating func add(css: String) {
        let text = Self.stripComments(css)
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "{") {
            let selectors = String(text[index ..< open])
            guard let close = Self.endOfBlock(in: text, from: text.index(after: open)) else { return }
            let body = String(text[text.index(after: open) ..< close])
            // An at-rule — `@media`, `@supports`, `@font-face`, `@page`. Its
            // braces are skipped whole: a rule inside a media query is one this
            // reader cannot decide the truth of, and `@font-face` belongs to
            // `EPUBFontResolver`, which reads the sheet for itself.
            if !selectors.contains("@") {
                let declarations = Self.declarations(in: body)
                if !declarations.isEmpty {
                    for selector in Self.selectors(in: selectors) {
                        rules.append(Rule(
                            selector: selector, declarations: declarations, order: rules.count))
                    }
                }
            }
            index = text.index(after: close)
        }
    }

    /// Appends an already-parsed sheet, keeping it after everything here.
    ///
    /// Sheets are parsed once per book and merged per document, so a chapter
    /// pays for its cascade and not for the parsing of it.
    public mutating func add(_ other: EPUBStyleSheet) {
        let base = rules.count
        rules.append(contentsOf: other.rules.map {
            Rule(selector: $0.selector, declarations: $0.declarations, order: base + $0.order)
        })
    }

    /// What this sheet says about one element.
    ///
    /// `inlineStyle` is the element's own `style=` attribute, which wins over
    /// every rule regardless of specificity — as it does in a browser.
    public func declarations(
        tag: String, classes: String?, identifier: String?, inlineStyle: String? = nil,
    ) -> Declarations {
        let name = tag.lowercased()
        let classNames = Set(
            (classes ?? "").split(whereSeparator: \.isWhitespace).map { $0.lowercased() })
        let id = identifier?.lowercased()

        var resolved = Declarations()
        for rule in rules
            .filter({ $0.selector.matches(tag: name, classes: classNames, identifier: id) })
            .sorted(by: { ($0.selector.specificity, $0.order) < ($1.selector.specificity, $1.order) }) {
            resolved.merge(rule.declarations)
        }
        if let inlineStyle, !inlineStyle.isEmpty {
            resolved.merge(Self.declarations(in: inlineStyle))
        }
        return resolved
    }

    public var isEmpty: Bool { rules.isEmpty }

    // MARK: - Reading selectors

    static func selectors(in list: String) -> [Selector] {
        list.split(separator: ",").compactMap { selector(from: String($0)) }
    }

    /// One selector, or `nil` when it is outside the supported shapes.
    static func selector(from raw: String) -> Selector? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        // A combinator, a pseudo-class, an attribute selector: all mean the rule
        // applies to something this reader cannot identify, so it matches
        // nothing rather than matching too much.
        guard !text.contains(where: { $0 == " " || $0 == ">" || $0 == "+" || $0 == "~" }),
              !text.contains(":"), !text.contains("["), !text.contains("(")
        else { return nil }
        if text == "*" { return Selector() }

        var selector = Selector()
        var current = ""
        var kind: Character = " "
        // Refusing a shape means refusing the *whole* selector, and tracking
        // that in a flag rather than by clearing a field. Clearing was the bug:
        // `div.a.b` dropped the second class and kept the tag, so a rule meant
        // for one kind of div silently applied to every div in the book —
        // precisely the half-applied rule this type exists not to produce.
        var supported = true
        func commit() {
            guard !current.isEmpty else {
                // A separator with nothing after it — `p.`, `#` — is malformed,
                // and it used to leave a bare tag behind that matched
                // everything.
                if kind != " " { supported = false }
                return
            }
            switch kind {
            case ".":
                if selector.klass != nil { supported = false }
                selector.klass = current
            case "#":
                if selector.identifier != nil { supported = false }
                selector.identifier = current
            default: selector.tag = current
            }
            current = ""
        }
        for character in text {
            if character == "." || character == "#" {
                commit()
                kind = character
            } else {
                current.append(character)
            }
        }
        commit()
        guard supported,
              selector.tag != nil || selector.klass != nil || selector.identifier != nil
        else { return nil }
        return selector
    }

    /// The end of a block opened at `from`, counting nested braces so an
    /// `@media` wrapper is skipped whole rather than ending at its first inner
    /// rule.
    static func endOfBlock(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                if depth == 0 { return index }
                depth -= 1
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Reading declarations

    static func declarations(in body: String) -> Declarations {
        var declarations = Declarations()
        for statement in body.split(separator: ";") {
            let parts = statement.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let property = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty else { continue }
            switch property {
            case "font-style":
                // `oblique` is a slanted roman where an italic is a different
                // drawing, but a reader asking for one will accept the other,
                // and the alternative is rendering the passage upright.
                declarations.italic = value == "italic" || value.hasPrefix("oblique")
                    ? true
                    : (value == "normal" ? false : nil)
            case "font-weight":
                declarations.bold = Self.isBold(value)
            case "text-align":
                declarations.alignment = Alignment(rawValue: value)
                    ?? (value == "start" ? .left : (value == "end" ? .right : nil))
            case "text-indent":
                declarations.textIndent = Self.length(value)
            case "font-size":
                // A non-positive size is refused rather than obeyed: a book
                // asking for zero is asking for nothing renderable, and a page
                // set in a zero-point font is blank with no setting a reader
                // could use to get it back.
                declarations.fontScale = Self.length(value)
                    .map { length in
                        switch length {
                        case let .fraction(value): value
                        case let .ems(value): value
                        }
                    }
                    .flatMap { $0 > 0 ? $0 : nil }
            case "text-decoration", "text-decoration-line":
                declarations.underlined = value.contains("underline")
                    ? true
                    : (value.contains("none") ? false : nil)
            case "font-family":
                let families = value
                    .split(separator: ",")
                    .map { unquote($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .filter { !$0.isEmpty }
                if !families.isEmpty { declarations.families = families }
            default:
                continue
            }
        }
        return declarations
    }

    /// Whether a `font-weight` asks for a heavier face.
    ///
    /// 600 is where CSS puts semibold, and a reading face that has one member
    /// heavier than regular answers to all of them.
    static func isBold(_ value: String) -> Bool? {
        switch value {
        case "bold", "bolder": true
        case "normal", "lighter": false
        default: Int(value).map { $0 >= 600 }
        }
    }

    /// A length, in the two forms that can be resolved without a layout engine.
    ///
    /// `pt`, `px`, `cm` and friends return `nil` deliberately: see `Length`.
    static func length(_ value: String) -> Length? {
        if value == "0" { return .fraction(0) }
        if value.hasSuffix("%") {
            return Double(value.dropLast()).map { .fraction($0 / 100) }
        }
        if value.hasSuffix("rem") {
            return Double(value.dropLast(3)).map { .ems($0) }
        }
        if value.hasSuffix("em") {
            return Double(value.dropLast(2)).map { .ems($0) }
        }
        return nil
    }

    // MARK: - Shared text handling

    /// Removes `/* … */`, which CSS permits anywhere. Left in, a comment before
    /// a rule becomes part of its selector and a comment inside a block corrupts
    /// the declaration it interrupts.
    static func stripComments(_ css: String) -> String {
        var result = ""
        result.reserveCapacity(css.count)
        var rest = Substring(css)
        while let open = rest.range(of: "/*") {
            result += rest[..<open.lowerBound]
            guard let close = rest.range(of: "*/", range: open.upperBound ..< rest.endIndex) else {
                // An unterminated comment swallows the rest of the sheet, which
                // is how a browser tokenises it.
                return result
            }
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }

    static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote) && value.count > 1 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}
