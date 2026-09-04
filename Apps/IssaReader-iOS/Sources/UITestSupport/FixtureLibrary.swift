#if ISSA_UITEST_FIXTURE
import Foundation

/// The catalogue the layout sweep lays out.
///
/// Built in Swift rather than read from a bundled JSON file. A resource added
/// to the app target ships in Release too — XcodeGen cannot condition resources
/// per configuration — and "forty kilobytes of dead JSON in the IPA" is an
/// argument that would have to be had at every release. Building the rows here
/// makes the question disappear: the whole file compiles out.
///
/// Deliberately awkward data. A layout sweep run against three tidy books
/// proves nothing; these are chosen for the shapes that have actually broken
/// this app — a title that wraps to three lines, an author list longer than the
/// cell, a description with no paragraph breaks, a book at 99%.
enum FixtureLibrary {
    /// The readalong book, whose EPUB the sweep script plants on disk so the
    /// reader screen opens without a download.
    static let readalongUUID = "11111111-1111-4111-8111-111111111111"

    private struct Row {
        let uuid: String
        let title: String
        let author: String
        let progress: Double?
        let formats: [String]
        /// The server's shelf name. Without one, `LibraryFilter.stage(of:)`
        /// files a book as `.toRead` — it never consults position — so a
        /// fixture with no statuses put all six books on one shelf, the chips
        /// read "Reading 0 · To read 6 · Finished 0" beside a book at 99%, and
        /// the Reading tab's "Also reading" block was empty at every width.
        var status: String? = nil
        /// Drives the Recently-added rail, which filters on a non-nil value and
        /// so never rendered at all.
        var createdAt: String? = nil
        /// Two books share a series so `SeriesRail` — the only producer of the
        /// `rail.series` identifier, and the one rail with a differently shaped
        /// header — is actually on screen to be measured.
        var series: (name: String, position: Double)? = nil
    }

    private static let rows: [Row] = [
        Row(uuid: readalongUUID,
            title: "Peter and Wendy",
            author: "J. M. Barrie",
            progress: 0.51,
            formats: ["readaloud", "ebook"],
            status: "Reading",
            createdAt: "2026-08-30T09:00:00.000Z"),
        Row(uuid: "22222222-2222-4222-8222-222222222222",
            // Long enough to wrap, which is the case that broke the shelf.
            title: "Frankenstein; or, the Modern Prometheus",
            author: "Mary Wollstonecraft Shelley",
            progress: 0.04,
            formats: ["ebook"],
            status: "Reading",
            createdAt: "2026-08-28T09:00:00.000Z"),
        Row(uuid: "33333333-3333-4333-8333-333333333333",
            title: "This Is How You Lose the Time War",
            // Two authors, which is what pushed a byline past its cover.
            author: "Amal El-Mohtar and Max Gladstone",
            progress: nil,
            formats: ["ebook", "audiobook"],
            status: "To read",
            createdAt: "2026-09-01T09:00:00.000Z"),
        Row(uuid: "44444444-4444-4444-8444-444444444444",
            title: "Dracula",
            author: "Bram Stoker",
            // Nearly finished: the bar at its widest, and "99%" not "100%".
            progress: 0.99,
            formats: ["ebook"],
            status: "Finished",
            createdAt: "2026-07-04T09:00:00.000Z",
            series: (name: "Gothic Horror", position: 1)),
        Row(uuid: "55555555-5555-4555-8555-555555555555",
            title: "Pride and Prejudice",
            author: "Jane Austen",
            progress: 0.33,
            formats: ["ebook", "readaloud"],
            status: "Reading",
            createdAt: "2026-08-15T09:00:00.000Z"),
        Row(uuid: "66666666-6666-4666-8666-666666666666",
            title: "The Ballad of Songbirds and Snakes",
            author: "Suzanne Collins",
            progress: nil,
            formats: ["ebook"],
            status: "To read",
            createdAt: "2026-08-20T09:00:00.000Z",
            series: (name: "Gothic Horror", position: 2)),
    ]

    static var booksJSON: Data {
        let objects = rows.map { row -> [String: Any] in
            var book: [String: Any] = [
                "uuid": row.uuid,
                "title": row.title,
                "description": Self.description,
                // `uuid` on every one of these: `Creator` and `Tag` both
                // require it, and a nested decode failure throws the whole
                // catalogue away — which is exactly what happened the first
                // time, and exactly why the fixture answers HTTP rather than
                // handing `AppModel` a pile of ready-made values.
                "authors": [["uuid": "\(row.uuid)-aut", "name": row.author, "role": "aut"]],
                "narrators": row.formats.contains("readaloud")
                    ? [["uuid": "\(row.uuid)-nrt", "name": "A Narrator", "role": "nrt"]] : [],
                "creators": [],
                                "tags": [
                    ["uuid": "tag-classics", "name": "Classics"],
                    ["uuid": "tag-fiction", "name": "Fiction"],
                ],
                "collections": [],
                "identifiers": [],
            ]
            if let status = row.status {
                book["status"] = ["uuid": "status-\(status)", "name": status]
            }
            if let createdAt = row.createdAt { book["createdAt"] = createdAt }
            if let series = row.series {
                book["series"] = [[
                    "uuid": "series-\(series.name)",
                    "name": series.name,
                    "position": series.position,
                ]]
            }
            // One key per format, as the server sends them — not a `formats`
            // array. `servableFormats` reads `filepath` and `missing`, and a
            // shape it does not recognise is a book with no way to open it.
            for format in row.formats {
                book[format] = [
                    "uuid": "\(row.uuid)-\(format)",
                    "filepath": "\(row.uuid)-\(format).epub",
                    "missing": false,
                    // Not optional on any of the three format structs.
                    "identifiers": [],
                ]
            }
            if let progress = row.progress {
                book["position"] = [
                    "locator": [
                        // What make-readalong-fixture.py actually writes. It was
                        // OEBPS/text/ch01.xhtml, a path in no generated archive —
                        // invisible only because no sweep destination opened the
                        // reader, so the cost of planting the EPUB bought nothing.
                        "href": "OEBPS/ch01.xhtml",
                        "type": "application/xhtml+xml",
                        "locations": ["totalProgression": progress, "progression": progress],
                    ],
                    "timestamp": 1_756_000_000_000,
                ]
            }
            return book
        }
        return (try? JSONSerialization.data(withJSONObject: objects)) ?? Data("[]".utf8)
    }

    static let userJSON = Data("""
        {"id":"fixture-user","name":"Sweep","username":"sweep",
         "permissions":{"bookList":true,"bookDownload":true,"bookRead":true}}
        """.utf8)

    static let emptyArrayJSON = Data("[]".utf8)

    /// One long paragraph with no breaks, which is what a real catalogue is
    /// full of and what makes a detail screen's measure worth checking.
    private static let description = """
        A story about people who go somewhere and find that the place is not \
        what they were told it was, and about what they decide to do once they \
        know. It is long enough here to wrap several times at every width this \
        sweep runs at, which is the entire point of putting it in a fixture.
        """
}
#endif
