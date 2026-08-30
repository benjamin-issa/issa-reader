import Foundation

/// Storyteller emits two different date formats in the same JSON object.
///
/// Verified against a live `web-v2.14.21` server:
/// - Row timestamps (`createdAt`, `updatedAt`) come straight out of SQLite as
///   `"2026-08-30 03:51:47"` — space-separated, no timezone, implicitly UTC.
/// - Metadata dates (`publicationDate`) are ISO 8601 with milliseconds and a
///   `Z` suffix: `"1998-06-01T00:00:00.000Z"`.
///
/// A single `JSONDecoder.dateDecodingStrategy` therefore cannot work; this type
/// wraps the parsing so models can declare plain date properties.
public enum StorytellerDate {
    /// UTC, POSIX locale, Gregorian — never the device's calendar or locale.
    private static let sqlite: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // `ISO8601DateFormatter` is a non-Sendable reference type and cannot be a
    // shared static under strict concurrency. The `FormatStyle` equivalents are
    // value types, so they are safe to share and cheap to copy.
    private static let iso8601Fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso8601 = Date.ISO8601FormatStyle()

    /// Parses either shape, or returns `nil` for anything unrecognised.
    public static func parse(_ string: String) -> Date? {
        if let date = sqlite.date(from: string) { return date }
        if let date = try? iso8601Fractional.parse(string) { return date }
        if let date = try? iso8601.parse(string) { return date }
        return nil
    }

    /// Renders in the SQLite shape the server uses for row timestamps.
    public static func sqliteString(from date: Date) -> String {
        sqlite.string(from: date)
    }
}

/// A date that decodes from either Storyteller date format.
///
/// A malformed value throws rather than silently yielding a wrong instant — a
/// book that sorts to 1970 is much harder to notice than a decode error.
public struct FlexibleDate: Codable, Hashable, Sendable, Comparable {
    public var value: Date

    public init(_ value: Date) { self.value = value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = StorytellerDate.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised Storyteller date format: \(raw)",
            )
        }
        value = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(StorytellerDate.sqliteString(from: value))
    }

    public static func < (lhs: FlexibleDate, rhs: FlexibleDate) -> Bool {
        lhs.value < rhs.value
    }
}
