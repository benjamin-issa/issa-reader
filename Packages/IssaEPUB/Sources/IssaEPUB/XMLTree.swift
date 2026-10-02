import Foundation

/// A minimal XML tree, built on the system parser.
///
/// Models mixed content properly: `text` is what appears before the first
/// child, and each child carries the `tail` text that follows it. Without that
/// distinction `<p>Hello <b>world</b> again</p>` loses the word "again", or
/// reorders it — which is exactly the class of bug that makes a reader subtly
/// mangle ordinary prose.
public final class EPUBXMLNode: @unchecked Sendable {
    public let name: String
    public var attributes: [String: String]
    /// Character data before the first child element.
    public var text: String = ""
    /// Character data immediately after this element, belonging to its parent.
    public var tail: String = ""
    public private(set) var children: [EPUBXMLNode] = []
    public weak var parent: EPUBXMLNode?

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    func add(_ child: EPUBXMLNode) {
        child.parent = self
        children.append(child)
    }

    public func children(_ localName: String) -> [EPUBXMLNode] {
        children.filter { $0.name == localName }
    }

    public func firstChild(_ localName: String) -> EPUBXMLNode? {
        children.first { $0.name == localName }
    }

    /// Depth-first search by local name.
    public func descendants(_ localName: String) -> [EPUBXMLNode] {
        var found: [EPUBXMLNode] = []
        for child in children {
            if child.name == localName { found.append(child) }
            found.append(contentsOf: child.descendants(localName))
        }
        return found
    }

    public func firstDescendant(named localName: String) -> EPUBXMLNode? {
        if name.lowercased() == localName.lowercased() { return self }
        for child in children {
            if let hit = child.firstDescendant(named: localName) { return hit }
        }
        return nil
    }

    /// All character data beneath this node, in document order.
    public var allText: String {
        var result = text
        for child in children {
            result += child.allText
            result += child.tail
        }
        return result
    }

    /// Leading text with surrounding whitespace removed, for metadata fields.
    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public subscript(attribute: String) -> String? { attributes[attribute] }
}

public enum EPUBXML {
    /// Parses into a tree, matching on local names.
    ///
    /// EPUB documents vary wildly in whether and how they prefix `opf:`, `dc:`,
    /// `epub:` and `smil:`. Matching the local name is what makes this work
    /// against real books rather than only tidy ones.
    public static func parse(_ data: Data) throws -> EPUBXMLNode {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        if delegate.exceededDepth {
            throw EPUBError.malformedPackage(
                "elements nested deeper than \(EPUBXML.maximumDepth); refusing to walk it")
        }
        guard parsed, let root = delegate.root else {
            throw EPUBError.malformedPackage(
                parser.parserError?.localizedDescription ?? "XML parse failed",
            )
        }
        return root
    }

    /// Parses XHTML that may name HTML entities XML does not define.
    ///
    /// For anything a book's author wrote as HTML — a chapter, a navigation
    /// document, an NCX — rather than a package file a tool generated. Those
    /// routinely say `&nbsp;`, and an XHTML file under the HTML5 short DOCTYPE
    /// (or none, which is nearly all of them) declares no entities at all, so
    /// `XMLParser` fails the whole document with error 111. With
    /// `substitutingHTMLEntities` false this is exactly `parse(_:)`.
    public static func parse(_ data: Data, substitutingHTMLEntities: Bool) throws -> EPUBXMLNode {
        try parse(substitutingHTMLEntities ? Self.substitutingHTMLEntities(in: data) : data)
    }

    /// Rewrites every HTML 4.01 named entity XML does not predefine as a
    /// numeric reference, in one pass.
    ///
    /// One pass, not one per entity: the first version was
    /// `for (name, code) in table { replacingOccurrences }`, a full scan and a
    /// new String per name, which on a 400 KB chapter was slow enough to notice
    /// once the table was complete. Scanning once and looking each name up
    /// costs the same for a table of any size.
    ///
    /// Data that is not UTF-8, or holds no `&`, is returned untouched.
    public static func substitutingHTMLEntities(in data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        guard text.contains("&") else { return data }

        var out = String()
        out.reserveCapacity(text.count)
        var index = text.startIndex

        while let amp = text[index...].firstIndex(of: "&") {
            out.append(contentsOf: text[index ..< amp])
            // A name is letters and digits, then a semicolon. Bail out at a
            // reasonable width rather than scanning to the end of the document
            // for a stray `&` — prose is full of them.
            let after = text.index(after: amp)
            let limit = text.index(after, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
            if let semicolon = text[after ..< limit].firstIndex(of: ";") {
                let name = String(text[after ..< semicolon])
                if let code = htmlNamedEntities[name] {
                    out.append("&#\(code);")
                    index = text.index(after: semicolon)
                    continue
                }
            }
            // Not one of ours: the five XML predefined entities, a numeric
            // reference, or a bare ampersand. All are the parser's business.
            out.append("&")
            index = after
        }
        out.append(contentsOf: text[index...])
        return Data(out.utf8)
    }

    /// Every HTML 4.01 named entity that XML does not predefine, mapped to its
    /// code point: all 252 of the HTML 4.01 (and XHTML 1.x) set except `amp`,
    /// `lt`, `gt` and `quot`. `apos` is XML's own and not in HTML 4.01.
    ///
    /// **Complete, and it has to be.** A name missing here reaches `XMLParser`
    /// as an undefined entity: under the HTML5 DOCTYPE or none that fails the
    /// parse — the chapter will not open, and search and Ask skip it silently —
    /// and under an XHTML 1.x DOCTYPE the parse succeeds and the character is
    /// quietly dropped (libxml2 does *not* resolve them for us, whatever an
    /// earlier comment claimed). The renderer's table stopped at two hundred,
    /// and the forty-eight it lacked — `&asymp;`, `&sum;`, `&there4;`, the
    /// double arrows — are the last group below.
    ///
    /// `lang` and `rang` keep their HTML 4.01 code points (U+2329, U+232A), not
    /// HTML5's U+27E8 and U+27E9; that is the set an XHTML 1.x book was written
    /// against.
    public static let htmlNamedEntities: [String: Int] = [
        // Latin-1 punctuation and symbols
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "curren": 164,
        "yen": 165, "brvbar": 166, "sect": 167, "uml": 168, "copy": 169,
        "ordf": 170, "laquo": 171, "not": 172, "shy": 173, "reg": 174,
        "macr": 175, "deg": 176, "plusmn": 177, "sup2": 178, "sup3": 179,
        "acute": 180, "micro": 181, "para": 182, "middot": 183, "cedil": 184,
        "sup1": 185, "ordm": 186, "raquo": 187, "frac14": 188, "frac12": 189,
        "frac34": 190, "iquest": 191, "times": 215, "divide": 247,

        // Latin-1 letters, uppercase
        "Agrave": 192, "Aacute": 193, "Acirc": 194, "Atilde": 195, "Auml": 196,
        "Aring": 197, "AElig": 198, "Ccedil": 199, "Egrave": 200, "Eacute": 201,
        "Ecirc": 202, "Euml": 203, "Igrave": 204, "Iacute": 205, "Icirc": 206,
        "Iuml": 207, "ETH": 208, "Ntilde": 209, "Ograve": 210, "Oacute": 211,
        "Ocirc": 212, "Otilde": 213, "Ouml": 214, "Oslash": 216, "Ugrave": 217,
        "Uacute": 218, "Ucirc": 219, "Uuml": 220, "Yacute": 221, "THORN": 222,

        // Latin-1 letters, lowercase
        "szlig": 223, "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227,
        "auml": 228, "aring": 229, "aelig": 230, "ccedil": 231, "egrave": 232,
        "eacute": 233, "ecirc": 234, "euml": 235, "igrave": 236, "iacute": 237,
        "icirc": 238, "iuml": 239, "eth": 240, "ntilde": 241, "ograve": 242,
        "oacute": 243, "ocirc": 244, "otilde": 245, "ouml": 246, "oslash": 248,
        "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252, "yacute": 253,
        "thorn": 254, "yuml": 255,

        // Latin Extended-A, the ligatures and carons a European text uses
        "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353, "Yuml": 376,
        "fnof": 402,

        // Greek
        "Alpha": 913, "Beta": 914, "Gamma": 915, "Delta": 916, "Epsilon": 917,
        "Zeta": 918, "Eta": 919, "Theta": 920, "Iota": 921, "Kappa": 922,
        "Lambda": 923, "Mu": 924, "Nu": 925, "Xi": 926, "Omicron": 927,
        "Pi": 928, "Rho": 929, "Sigma": 931, "Tau": 932, "Upsilon": 933,
        "Phi": 934, "Chi": 935, "Psi": 936, "Omega": 937,
        "alpha": 945, "beta": 946, "gamma": 947, "delta": 948, "epsilon": 949,
        "zeta": 950, "eta": 951, "theta": 952, "iota": 953, "kappa": 954,
        "lambda": 955, "mu": 956, "nu": 957, "xi": 958, "omicron": 959,
        "pi": 960, "rho": 961, "sigmaf": 962, "sigma": 963, "tau": 964,
        "upsilon": 965, "phi": 966, "chi": 967, "psi": 968, "omega": 969,

        // Punctuation and spaces
        "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205,
        "lrm": 8206, "rlm": 8207, "ndash": 8211, "mdash": 8212, "lsquo": 8216,
        "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221, "bdquo": 8222,
        "dagger": 8224, "Dagger": 8225, "bull": 8226, "hellip": 8230,
        "permil": 8240, "prime": 8242, "Prime": 8243, "lsaquo": 8249,
        "rsaquo": 8250, "oline": 8254, "frasl": 8260, "euro": 8364,

        // Arrows and maths
        "trade": 8482, "larr": 8592, "uarr": 8593, "rarr": 8594, "darr": 8595,
        "harr": 8596, "minus": 8722, "lowast": 8727, "radic": 8730,
        "infin": 8734, "cap": 8745, "cup": 8746, "int": 8747, "ne": 8800,
        "equiv": 8801, "le": 8804, "ge": 8805, "loz": 9674, "spades": 9824,
        "clubs": 9827, "hearts": 9829, "diams": 9830,

        // The rest of HTML 4.01: spacing modifiers, Greek symbols, letterlike
        // symbols, double arrows, and the mathematical operators.
        "circ": 710, "tilde": 732, "thetasym": 977, "upsih": 978, "piv": 982,
        "image": 8465, "weierp": 8472, "real": 8476, "alefsym": 8501, "crarr": 8629,
        "lArr": 8656, "uArr": 8657, "rArr": 8658, "dArr": 8659, "hArr": 8660,
        "forall": 8704, "part": 8706, "exist": 8707, "empty": 8709, "nabla": 8711,
        "isin": 8712, "notin": 8713, "ni": 8715, "prod": 8719, "sum": 8721,
        "prop": 8733, "ang": 8736, "and": 8743, "or": 8744, "there4": 8756,
        "sim": 8764, "cong": 8773, "asymp": 8776, "sub": 8834, "sup": 8835,
        "nsub": 8836, "sube": 8838, "supe": 8839, "oplus": 8853, "otimes": 8855,
        "perp": 8869, "sdot": 8901, "lceil": 8968, "rceil": 8969, "lfloor": 8970,
        "rfloor": 8971, "lang": 9001, "rang": 9002,
    ]

    /// How deeply an element may nest before the document is refused.
    ///
    /// `XMLParser` imposes no limit of its own — measured: 200, 300, 1,000 and
    /// 50,000 levels all parse successfully with this exact delegate
    /// configuration — and the tree it produces is walked recursively by
    /// `descendants`, `firstDescendant`, `allText`, `HTMLContentParser.render`,
    /// `SMILParser.walk` and `EPUBPackage.flatten`, none of which has a base
    /// case other than running out of children. The ARC release chain through
    /// `children` recurses too, so even an iterative rewrite of the walks would
    /// leave teardown exposed.
    ///
    /// That makes deep nesting a stack overflow — `EXC_BAD_ACCESS`, not a
    /// thrown error, so the `try?` wrappers around every parse catch nothing.
    /// 150,000 nested elements is about 1.2 MB of XHTML that deflates to a few
    /// hundred bytes, a ratio well inside the archive guards. The iOS main
    /// thread has a 1 MB stack against macOS's 8, so a desktop repro understates
    /// the real threshold by an order of magnitude.
    ///
    /// 512 is far past anything a book does — real XHTML rarely exceeds twenty —
    /// and far short of what any of those walks can survive.
    static let maximumDepth = 512

    private final class Builder: NSObject, XMLParserDelegate {
        var root: EPUBXMLNode?
        private var stack: [EPUBXMLNode] = []
        private(set) var exceededDepth = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String],
        ) {
            // Namespaces are processed, so elementName is the local name — but
            // attribute keys still arrive qualified (e.g. `epub:type`), so both
            // forms are indexed.
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict {
                attributes[key] = value
                if let colon = key.firstIndex(of: ":") {
                    attributes[String(key[key.index(after: colon)...])] = value
                }
            }
            guard stack.count < EPUBXML.maximumDepth else {
                // Abort rather than keep building: the tree is already deep
                // enough that walking it is the hazard, and `abortParsing`
                // makes `parse()` return false so this surfaces as a thrown
                // `malformedPackage` at the call site.
                exceededDepth = true
                parser.abortParsing()
                return
            }
            let node = EPUBXMLNode(name: elementName, attributes: attributes)
            if let current = stack.last { current.add(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let current = stack.last else { return }
            // Text after a child belongs to that child's tail, not to the
            // parent's leading text.
            if let lastChild = current.children.last {
                lastChild.tail += string
            } else {
                current.text += string
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
            self.parser(parser, foundCharacters: string)
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
        ) {
            _ = stack.popLast()
        }
    }
}
