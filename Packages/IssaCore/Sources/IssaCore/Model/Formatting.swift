import Foundation

/// A length of audio as a reader sees it: "2h 18m", "45m".
///
/// One copy. There were three — the detail screen's, the widget snapshot's
/// and CarPlay's — and only CarPlay's guarded against a non-finite value, so a
/// server-supplied duration of NaN trapped in `Int(seconds.rounded())` on the
/// book screen while the car showed "0m".
public enum DurationText {
    public static func text(_ seconds: Double) -> String {
        // `wholeSeconds`, not `isFinite` plus `Int(_:)`. The guard was there and
        // was not enough: `1e300` is finite, and converting it traps.
        guard seconds > 0, let total = seconds.wholeSeconds else { return "0m" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// A byte count as a reader sees it: "146.2 MB".
public enum ByteCountText {
    public static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Where a book sits in a series, as a reader sees it: "2", "Book 1.5",
/// "Gothic Horror · Book 2 of 3".
///
/// One copy, because the same three words are wanted in four places at three
/// lengths — a badge on a cover has room for a numeral, a caption under it has
/// room for the series name, and the book screen has room to say how many
/// there are. Splitting them here keeps the phrasing identical wherever the
/// reader meets it.
public enum SeriesText {
    /// The position on its own, for a mark too small for a word.
    ///
    /// Formatted rather than interpolated. A position is a `Double` and a
    /// novella legitimately sits at 1.5, so `"\(position)"` prints "2.0" for
    /// the ordinary case and can print "1.5000001" for the fractional one.
    public static func ordinal(_ position: Double) -> String {
        // A fixed locale, not the reader's. "Book" and "of" around this numeral
        // are hard-coded English, so a device set to German would have produced
        // "Book 1,5 of 3" — half-translated — and a four-figure series would
        // have grown a grouping separator the rest of the app never shows.
        position.formatted(
            .number.locale(Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(0 ... 2)),
        )
    }

    /// The position as a phrase: "Book 2", "Book 1.5".
    public static func position(_ position: Double) -> String {
        "Book \(ordinal(position))"
    }

    /// The whole line: the series, where in it, and how long it is.
    ///
    /// `count` is what the library knows rather than what the book knows — the
    /// server numbers a book within its series but never says how many there
    /// are — so it is passed in, and left out where it is not known. "of 1" is
    /// never said: a series of one is a book, and the count only adds anything
    /// once there is somewhere else to go.
    /// - Parameter count: how many books of the series the *library holds*,
    ///   which is not how long the series is — the server numbers a book within
    ///   its series and never says how many there are. So "of N" is said only
    ///   when it can be true: own books 1 and 3 of five and the third is "Book
    ///   3", not "Book 3 of 2".
    public static func label(name: String, position: Double?, count: Int?) -> String {
        guard let position else { return name }
        var text = "\(name) · \(self.position(position))"
        if let count, count > 1, Double(count) >= position { text += " of \(count)" }
        return text
    }
}
