import Foundation

public extension Book {
    /// This book's place in one named series, or nil when it is not in it.
    ///
    /// Always by the series' name, never `series.first` or `primarySeries`:
    /// an omnibus filed first under its own series and second under the
    /// publisher's has two numbers, and a screen about the publisher's series
    /// has to show the publisher's. The series screen, the book page's series
    /// rail and `SeriesGroup.position(of:)` all ask the same question, so it
    /// is answered once here.
    func membership(inSeries name: String) -> SeriesMembership? {
        series.first { $0.name == name }
    }

    /// The book's tags with each name once, in the order the server sent them.
    ///
    /// A tag is identified to a reader by its name — every grouping, filter and
    /// page in the app keys on it — but the server can list the same name
    /// twice (two rows with different uuids, or the same row repeated). Drawn
    /// as-is that is two identical chips, and a `ForEach` over the uuid gives
    /// two views one identity. The first of each name is kept.
    var distinctTags: [Tag] {
        var seen: Set<String> = []
        return tags.filter { seen.insert($0.name).inserted }
    }
}
