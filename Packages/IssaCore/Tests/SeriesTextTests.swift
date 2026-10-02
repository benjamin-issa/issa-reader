import Foundation
import Testing

@testable import IssaCore

/// How a series is worded, and which membership a screen with one line shows.
///
/// The phrasing is pinned here because three screens draw it — the badge on a
/// cover of the series screen, that screen's caption, and the book screen's
/// hero — and the point of one formatter is that they cannot drift apart.
@Suite("Wording a series")
struct SeriesTextTests {
    /// Decoded, like every other fixture: the model has no public initialiser.
    func book(_ title: String, series: [(name: String, position: Double?)]) -> Book {
        let json: [String: Any] = [
            "uuid": title, "title": title,
            "authors": [], "narrators": [], "creators": [], "collections": [],
            "identifiers": [], "tags": [],
            "series": series.map { membership -> [String: Any] in
                var row: [String: Any] = ["uuid": membership.name, "name": membership.name]
                if let position = membership.position { row["position"] = position }
                return row
            },
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    @Test("a whole position loses its decimal point")
    func wholePosition() {
        #expect(SeriesText.ordinal(2) == "2")
        #expect(SeriesText.position(2) == "Book 2")
    }

    /// The case interpolation gets wrong in both directions: "2.0" for the
    /// ordinary book and "1.5000001" for the novella between two of them.
    @Test("a novella keeps its fraction and nothing else")
    func fractionalPosition() {
        #expect(SeriesText.ordinal(1.5) == "1.5")
        #expect(SeriesText.position(1.5) == "Book 1.5")
    }

    @Test("a label names the series, the book and how many there are")
    func fullLabel() {
        #expect(SeriesText.label(name: "Gothic Horror", position: 2, count: 3)
            == "Gothic Horror · Book 2 of 3")
        #expect(SeriesText.label(name: "Gothic Horror", position: 1.5, count: 3)
            == "Gothic Horror · Book 1.5 of 3")
    }

    /// An unnumbered membership is a shelf label: there is no "book 1" to name.
    @Test("a series with no position is just its name")
    func unpositioned() {
        #expect(SeriesText.label(name: "Gothic Horror", position: nil, count: 4) == "Gothic Horror")
    }

    /// "of 1" says a series of one, which is a book. The count only adds
    /// something once there is somewhere else to go.
    @Test("the count is said only when there is more than one book")
    func countOnlyWhenItMeansSomething() {
        #expect(SeriesText.label(name: "Solo", position: 1, count: nil) == "Solo · Book 1")
        #expect(SeriesText.label(name: "Solo", position: 1, count: 1) == "Solo · Book 1")
        #expect(SeriesText.label(name: "Pair", position: 1, count: 2) == "Pair · Book 1 of 2")
    }

    /// A book in two series: the badge and the caption have one line, so they
    /// take the membership that carries a number — the other one cannot say
    /// which book this is — while the book screen still names both.
    @Test("a book in two series shows the numbered one where there is room for one")
    func twoSeries() {
        let omnibus = book(
            "Collected", series: [(name: "Publisher's Library", position: nil), (name: "Gothic Horror", position: 3)])
        #expect(omnibus.primarySeries?.name == "Gothic Horror")

        let labels = omnibus.series.map {
            SeriesText.label(name: $0.name, position: $0.position, count: nil)
        }
        #expect(labels == ["Publisher's Library", "Gothic Horror · Book 3"])
    }

    /// Nothing numbered anywhere: the first membership is still the one to
    /// show, because a series name alone is better than no series at all.
    @Test("an unnumbered book still has a series to name")
    func noPositionAnywhere() {
        let book = book("Alone", series: [(name: "Gothic Horror", position: nil)])
        #expect(book.primarySeries?.name == "Gothic Horror")
        #expect(book.primarySeries?.position == nil)
    }

    @Test("a book in no series has none to name")
    func noSeries() {
        #expect(book("Alone", series: []).primarySeries == nil)
    }

    @Test("a series never claims more books than it can hold")
    func theCountMustContainThePosition() {
        // `count` is what the library holds, not how long the series is: own
        // books one and three of five and the third used to read "Book 3 of 2".
        #expect(SeriesText.label(name: "Gothic Horror", position: 3, count: 2)
            == "Gothic Horror · Book 3")
        #expect(SeriesText.label(name: "Gothic Horror", position: 4, count: 3)
            == "Gothic Horror · Book 4")
        // The honest cases still say it.
        #expect(SeriesText.label(name: "Gothic Horror", position: 2, count: 3)
            == "Gothic Horror · Book 2 of 3")
        #expect(SeriesText.label(name: "Gothic Horror", position: 3, count: 3)
            == "Gothic Horror · Book 3 of 3")
        #expect(SeriesText.label(name: "Gothic Horror", position: 1.5, count: 2)
            == "Gothic Horror · Book 1.5 of 2")
    }

    /// A series the library holds part of, books at these positions.
    private func held(_ name: String, at positions: [Double?]) -> SeriesGroup {
        SeriesGroup(name: name, books: positions.enumerated().map { index, position in
            book("\(name) \(index)", series: [(name: name, position: position)])
        })
    }

    /// The book screen passed the number of books the library holds as the
    /// count, so holding books 2 and 3 of a series read "Book 2 of 2" beside a
    /// "Book 3" the same library holds. The count is said only where nothing
    /// held contradicts it: the positions held are exactly 1 to N.
    @Test("a series states its length only when the books held are exactly the first N")
    func statedCountNeedsTheWholeRun() {
        #expect(held("Gothic", at: [1, 2]).statedCount == 2)
        #expect(held("Gothic", at: [3, 1, 2]).statedCount == 3, "in any order")
        #expect(held("Gothic", at: [2, 3]).statedCount == nil, "no book 1")
        #expect(held("Gothic", at: [1, 2, 5]).statedCount == nil, "a gap")
        #expect(held("Gothic", at: [1, 1.5, 2]).statedCount == nil, "a novella is not a numbered book")
        #expect(held("Gothic", at: [1, 1]).statedCount == nil, "two at one place")
        #expect(held("Gothic", at: [1, nil]).statedCount == nil, "an unnumbered book")
    }

    @Test(
        "the book screen says 'of N' only beside the run it holds from one",
        arguments: [
            ([2, 3] as [Double], [] as [String]),
            ([1, 2], ["Gothic Horror · Book 1 of 2", "Gothic Horror · Book 2 of 2"]),
            ([1, 2, 5], []),
        ])
    func bookScreenLabel(positions: [Double], wholeRun: [String]) {
        let group = held("Gothic Horror", at: positions)
        let labels = group.books.map { SeriesText.label(for: $0.series[0], in: group) }
        if wholeRun.isEmpty {
            #expect(labels.allSatisfy { !$0.contains(" of ") }, "\(labels)")
            #expect(labels.first == "Gothic Horror · Book \(SeriesText.ordinal(positions[0]))")
        } else {
            #expect(labels == wholeRun)
        }
    }

    /// A book alone in its series has no group, and so no count.
    @Test("a book with no group is labelled without a count")
    func noGroup() {
        let alone = book("Alone", series: [(name: "Gothic Horror", position: 2)])
        #expect(SeriesText.label(for: alone.series[0], in: nil) == "Gothic Horror · Book 2")
    }

    @Test("the numeral does not follow the device's locale")
    func theNumeralIsFixed() {
        // The words around it are English; a comma decimal among them would be
        // half a translation.
        #expect(SeriesText.ordinal(1.5) == "1.5")
        #expect(SeriesText.ordinal(1200) == "1200")
    }
}
