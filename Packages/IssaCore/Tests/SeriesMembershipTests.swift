import Foundation
import Testing

@testable import IssaCore

/// Which number a book wears on a screen about one series, and which tags it
/// shows once.
@Suite("A book's place in a series, and its tags")
struct SeriesMembershipTests {
    private func book(
        series: [(name: String, position: Double?)] = [],
        tags: [(uuid: String, name: String)] = [],
    ) -> Book {
        let json: [String: Any] = [
            "uuid": "u", "title": "A Book",
            "authors": [], "narrators": [], "creators": [], "collections": [], "identifiers": [],
            "tags": tags.map { ["uuid": $0.uuid, "name": $0.name] },
            "series": series.map { membership -> [String: Any] in
                var row: [String: Any] = ["uuid": membership.name, "name": membership.name]
                if let position = membership.position { row["position"] = position }
                return row
            },
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    @Test("an omnibus listed first and numbered there still shows its place in the rail's series")
    func omnibusShowsTheRailsNumber() {
        let omnibus = book(series: [(name: "Omnibus", position: 1), (name: "Gothic Horror", position: 2)])
        #expect(omnibus.membership(inSeries: "Gothic Horror")?.position == 2)
        // The badge's own pick would have said 1.
        #expect(omnibus.primarySeries?.position == 1)
    }

    @Test("an unnumbered membership is found, and has no number to draw")
    func unnumberedHasNoPosition() {
        let shelved = book(series: [(name: "Gothic Horror", position: nil)])
        #expect(shelved.membership(inSeries: "Gothic Horror") != nil)
        #expect(shelved.membership(inSeries: "Gothic Horror")?.position == nil)
    }

    @Test("a book outside the series has no membership in it")
    func outsideTheSeries() {
        #expect(book(series: [(name: "Other", position: 1)]).membership(inSeries: "Gothic Horror") == nil)
        #expect(book().membership(inSeries: "Gothic Horror") == nil)
    }

    @Test("a tag named twice is shown once, the first of it, in the server's order")
    func distinctTags() {
        let tagged = book(tags: [
            (uuid: "1", name: "Gothic"), (uuid: "2", name: "Horror"),
            (uuid: "3", name: "Gothic"), (uuid: "2", name: "Horror"),
        ])
        #expect(tagged.distinctTags.map(\.name) == ["Gothic", "Horror"])
        #expect(tagged.distinctTags.map(\.uuid) == ["1", "2"])
    }
}
