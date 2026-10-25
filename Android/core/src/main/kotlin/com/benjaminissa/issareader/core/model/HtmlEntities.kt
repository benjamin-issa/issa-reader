package com.benjaminissa.issareader.core.model

/**
 * HTML's named character references, for everything that decodes them: the
 * EPUB parser, which hands them to the XML reader as numeric references, and
 * the book descriptions `HtmlText` renders.
 *
 * One table, so a description and a chapter can never disagree about a name.
 * Names are case-sensitive, as HTML's are: `&Eacute;mile` is "Émile".
 */
object HtmlEntities {
    /**
     * Every HTML 4.01 named entity that XML does not predefine, mapped to its
     * code point: all 252 of the HTML 4.01 (and XHTML 1.x) set except `amp`,
     * `lt`, `gt` and `quot`. `apos` is XML's own and not in HTML 4.01.
     *
     * **Complete, and it has to be.** A name missing here reaches the XML
     * reader as an undefined entity, which fails the parse: the chapter will
     * not open, and search and Ask skip it silently.
     *
     * `lang` and `rang` keep their HTML 4.01 code points (U+2329, U+232A), not
     * HTML5's U+27E8 and U+27E9; that is the set an XHTML 1.x book was written
     * against.
     */
    val named: Map<String, Int> = mapOf(
        // Latin-1 punctuation and symbols
        "nbsp" to 160, "iexcl" to 161, "cent" to 162, "pound" to 163, "curren" to 164,
        "yen" to 165, "brvbar" to 166, "sect" to 167, "uml" to 168, "copy" to 169,
        "ordf" to 170, "laquo" to 171, "not" to 172, "shy" to 173, "reg" to 174,
        "macr" to 175, "deg" to 176, "plusmn" to 177, "sup2" to 178, "sup3" to 179,
        "acute" to 180, "micro" to 181, "para" to 182, "middot" to 183, "cedil" to 184,
        "sup1" to 185, "ordm" to 186, "raquo" to 187, "frac14" to 188, "frac12" to 189,
        "frac34" to 190, "iquest" to 191, "times" to 215, "divide" to 247,

        // Latin-1 letters, uppercase
        "Agrave" to 192, "Aacute" to 193, "Acirc" to 194, "Atilde" to 195, "Auml" to 196,
        "Aring" to 197, "AElig" to 198, "Ccedil" to 199, "Egrave" to 200, "Eacute" to 201,
        "Ecirc" to 202, "Euml" to 203, "Igrave" to 204, "Iacute" to 205, "Icirc" to 206,
        "Iuml" to 207, "ETH" to 208, "Ntilde" to 209, "Ograve" to 210, "Oacute" to 211,
        "Ocirc" to 212, "Otilde" to 213, "Ouml" to 214, "Oslash" to 216, "Ugrave" to 217,
        "Uacute" to 218, "Ucirc" to 219, "Uuml" to 220, "Yacute" to 221, "THORN" to 222,

        // Latin-1 letters, lowercase
        "szlig" to 223, "agrave" to 224, "aacute" to 225, "acirc" to 226, "atilde" to 227,
        "auml" to 228, "aring" to 229, "aelig" to 230, "ccedil" to 231, "egrave" to 232,
        "eacute" to 233, "ecirc" to 234, "euml" to 235, "igrave" to 236, "iacute" to 237,
        "icirc" to 238, "iuml" to 239, "eth" to 240, "ntilde" to 241, "ograve" to 242,
        "oacute" to 243, "ocirc" to 244, "otilde" to 245, "ouml" to 246, "oslash" to 248,
        "ugrave" to 249, "uacute" to 250, "ucirc" to 251, "uuml" to 252, "yacute" to 253,
        "thorn" to 254, "yuml" to 255,

        // Latin Extended-A, the ligatures and carons a European text uses
        "OElig" to 338, "oelig" to 339, "Scaron" to 352, "scaron" to 353, "Yuml" to 376,
        "fnof" to 402,

        // Greek
        "Alpha" to 913, "Beta" to 914, "Gamma" to 915, "Delta" to 916, "Epsilon" to 917,
        "Zeta" to 918, "Eta" to 919, "Theta" to 920, "Iota" to 921, "Kappa" to 922,
        "Lambda" to 923, "Mu" to 924, "Nu" to 925, "Xi" to 926, "Omicron" to 927,
        "Pi" to 928, "Rho" to 929, "Sigma" to 931, "Tau" to 932, "Upsilon" to 933,
        "Phi" to 934, "Chi" to 935, "Psi" to 936, "Omega" to 937,
        "alpha" to 945, "beta" to 946, "gamma" to 947, "delta" to 948, "epsilon" to 949,
        "zeta" to 950, "eta" to 951, "theta" to 952, "iota" to 953, "kappa" to 954,
        "lambda" to 955, "mu" to 956, "nu" to 957, "xi" to 958, "omicron" to 959,
        "pi" to 960, "rho" to 961, "sigmaf" to 962, "sigma" to 963, "tau" to 964,
        "upsilon" to 965, "phi" to 966, "chi" to 967, "psi" to 968, "omega" to 969,

        // Punctuation and spaces
        "ensp" to 8194, "emsp" to 8195, "thinsp" to 8201, "zwnj" to 8204, "zwj" to 8205,
        "lrm" to 8206, "rlm" to 8207, "ndash" to 8211, "mdash" to 8212, "lsquo" to 8216,
        "rsquo" to 8217, "sbquo" to 8218, "ldquo" to 8220, "rdquo" to 8221, "bdquo" to 8222,
        "dagger" to 8224, "Dagger" to 8225, "bull" to 8226, "hellip" to 8230,
        "permil" to 8240, "prime" to 8242, "Prime" to 8243, "lsaquo" to 8249,
        "rsaquo" to 8250, "oline" to 8254, "frasl" to 8260, "euro" to 8364,

        // Arrows and maths
        "trade" to 8482, "larr" to 8592, "uarr" to 8593, "rarr" to 8594, "darr" to 8595,
        "harr" to 8596, "minus" to 8722, "lowast" to 8727, "radic" to 8730,
        "infin" to 8734, "cap" to 8745, "cup" to 8746, "int" to 8747, "ne" to 8800,
        "equiv" to 8801, "le" to 8804, "ge" to 8805, "loz" to 9674, "spades" to 9824,
        "clubs" to 9827, "hearts" to 9829, "diams" to 9830,

        // The rest of HTML 4.01: spacing modifiers, Greek symbols, letterlike
        // symbols, double arrows, and the mathematical operators.
        "circ" to 710, "tilde" to 732, "thetasym" to 977, "upsih" to 978, "piv" to 982,
        "image" to 8465, "weierp" to 8472, "real" to 8476, "alefsym" to 8501, "crarr" to 8629,
        "lArr" to 8656, "uArr" to 8657, "rArr" to 8658, "dArr" to 8659, "hArr" to 8660,
        "forall" to 8704, "part" to 8706, "exist" to 8707, "empty" to 8709, "nabla" to 8711,
        "isin" to 8712, "notin" to 8713, "ni" to 8715, "prod" to 8719, "sum" to 8721,
        "prop" to 8733, "ang" to 8736, "and" to 8743, "or" to 8744, "there4" to 8756,
        "sim" to 8764, "cong" to 8773, "asymp" to 8776, "sub" to 8834, "sup" to 8835,
        "nsub" to 8836, "sube" to 8838, "supe" to 8839, "oplus" to 8853, "otimes" to 8855,
        "perp" to 8869, "sdot" to 8901, "lceil" to 8968, "rceil" to 8969, "lfloor" to 8970,
        "rfloor" to 8971, "lang" to 9001, "rang" to 9002,
    )

    private val xmlPredefined = mapOf("amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'")

    /**
     * The character a named reference stands for: any name in [named], or one
     * of the five XML predefines (`amp`, `lt`, `gt`, `quot`, `apos`).
     * Case-sensitive, so `Eacute` and `eacute` are the two letters they are.
     */
    fun character(name: String): String? {
        xmlPredefined[name]?.let { return it }
        val codePoint = named[name] ?: return null
        return String(Character.toChars(codePoint))
    }
}
