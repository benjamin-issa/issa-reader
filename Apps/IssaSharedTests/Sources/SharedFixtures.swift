import Foundation
import Testing

@testable import IssaCore

/// Values the Apps/Shared tests build from, in the shape the server sends them.
///
/// `Book` has no public initialiser, so every suite in this repo builds one by
/// decoding a dictionary — see `LibraryRailsTests.book(...)`, whose shape this
/// follows deliberately rather than inventing a second convention. Decoding is
/// also the honest route: it exercises the same `Codable` path the catalogue
/// takes, so a fixture that would not survive a real response does not silently
/// pass here.
enum SharedFixtures {
    static func book(
        _ title: String,
        uuid: String? = nil,
        status: String? = nil,
        progress: Double? = nil,
        positionTimestamp: Double? = nil,
        /// Which resource the stored position names, and on which clock its
        /// fraction is measured. Two clocks share `totalProgression` in this
        /// app — the reader's fraction of the text, the audiobook's fraction of
        /// the audio — and only the type tells them apart, so a suite about
        /// listening cannot use the reading default. See `AudioAnchor`.
        positionHref: String = "OEBPS/ch01.xhtml",
        positionType: String = "application/xhtml+xml",
        createdAt: String? = nil,
        readaloud: Bool = false,
        audiobook: Bool = false,
        ebook: Bool = true,
        authors: [String] = [],
        narrators: [String] = [],
    ) -> Book {
        var json: [String: Any] = [
            "uuid": uuid ?? title,
            "title": title,
            "authors": authors.map { ["uuid": $0, "name": $0] },
            "narrators": narrators.map { ["uuid": $0, "name": $0] },
            "creators": [], "collections": [],
            "identifiers": [], "tags": [], "series": [],
        ]
        if let status { json["status"] = ["uuid": status, "name": status] }
        if let progress {
            json["position"] = [
                "locator": [
                    "href": positionHref,
                    "type": positionType,
                    "locations": ["totalProgression": progress, "progression": progress],
                ],
                "timestamp": positionTimestamp ?? 0,
            ]
        }
        if let createdAt { json["createdAt"] = createdAt }
        if ebook { json["ebook"] = ["uuid": "e", "filepath": "e.epub", "identifiers": []] }
        if readaloud { json["readaloud"] = ["uuid": "r", "filepath": "r.epub", "identifiers": []] }
        if audiobook { json["audiobook"] = ["uuid": "a", "filepath": "a.m4b", "identifiers": []] }

        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    /// A `UserDefaults` suite of its own, removed when the test ends.
    ///
    /// `AppModel` reads and writes `UserDefaults.standard` in its initialiser,
    /// so a test that let it touch the real domain would leak state into the
    /// next one and into the simulator's own app.
    static func scratchDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

/// The harness itself, so a failure here is read as "the bundle is wrong"
/// rather than as a defect in whatever it was pointed at.
@Suite("The shared-app test bundle can reach the app's own types")
struct SharedTestBundleTests {
    /// `Apps/Shared/Sources` is a source path compiled into each app target,
    /// not a package, so `swift test` cannot see any of it. This bundle exists
    /// because forty-plus of the review's findings live in code that no test
    /// target could reach — if this stops compiling, that is the news.
    @Test("a Book decodes from the shape the catalogue sends")
    func decodesABook() throws {
        let book = SharedFixtures.book("Dracula", status: "Reading", progress: 0.99)
        #expect(book.title == "Dracula")
        #expect(book.status?.name == "Reading")
        let progression = try #require(book.position?.locator.locations?.totalProgression)
        #expect(abs(progression - 0.99) < 0.0001)
    }

    /// The classifier the sweep's fixture is built against. A status decides
    /// the shelf whenever there is one; only a book with none — which 3.x
    /// sends and never advances — is filed by its progress, at the server's
    /// own thresholds, where 2.x would have put it.
    @Test("a status decides the shelf, and progress decides only when there is none")
    func statusNotProgressDecidesTheShelf() {
        let finishedUnlabelled = SharedFixtures.book("Dracula", progress: 0.99)
        #expect(LibraryArrangement.stage(of: finishedUnlabelled) == .finished)

        let unstartedUnlabelled = SharedFixtures.book("Dracula", progress: 0)
        #expect(LibraryArrangement.stage(of: unstartedUnlabelled) == .toRead)

        let midwayUnlabelled = SharedFixtures.book("Dracula", progress: 0.4)
        #expect(LibraryArrangement.stage(of: midwayUnlabelled) == .reading)

        let labelled = SharedFixtures.book("Dracula", status: "Finished", progress: 0.99)
        #expect(
            LibraryArrangement.stage(of: labelled) == .finished,
            "the shelf must follow the server's status once there is one")

        let rereading = SharedFixtures.book("Dracula", status: "To read", progress: 0.99)
        #expect(
            LibraryArrangement.stage(of: rereading) == .toRead,
            "progress must not override a status the reader chose")
    }
}
