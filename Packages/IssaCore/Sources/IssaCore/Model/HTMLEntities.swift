import Foundation

/// HTML's named character references, for everything that decodes them: the
/// EPUB parser, which hands them to `XMLParser` as numeric references, and the
/// book descriptions `HTMLText` renders.
///
/// One table, so a description and a chapter can never disagree about a
/// name. Descriptions once went through a table of nineteen, looked up in
/// lower case: `&ntilde;` and `&uuml;` stayed raw on the book page and in
/// Spotlight, and `&Eacute;mile` became "émile". Names are case-sensitive,
/// as HTML's are.
public enum HTMLEntities {
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
    public static let named: [String: Int] = [
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

    /// The character a named reference stands for: any name in `named`, or
    /// one of the five XML predefines (`amp`, `lt`, `gt`, `quot`, `apos`).
    /// Case-sensitive, so `Eacute` and `eacute` are the two letters they are.
    public static func character(named name: String) -> Character? {
        if let predefined = xmlPredefined[name] { return predefined }
        return named[name]
            .flatMap { Unicode.Scalar(UInt32($0)) }
            .map(Character.init)
    }

    private static let xmlPredefined: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
    ]
}
