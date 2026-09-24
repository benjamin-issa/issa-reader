import Foundation
import Testing

@testable import IssaCore

/// The shelf and the status write agree about a book the server has not filed.
///
/// A book with no status is shelved by `LibraryArrangement.stage(of:)`, and the
/// first position this device writes for it files it through
/// `StatusAdvance.statusToSet`. The two read the progress separately and
/// disagreed at the start: the shelf kept a book at 0% — and one whose locator
/// carried no progression — on "To read", while the write, like the server's
/// own rule, filed it "Reading". These sweep the whole range and ask both, so a
/// line moved on one side alone cannot pass.
@Suite("The shelf agrees with the status a position files")
struct StageParityTests {
    private let statuses = [
        Status(uuid: "s-to-read", name: Status.toReadName),
        Status(uuid: "s-reading", name: Status.readingName),
        Status(uuid: "s-read", name: Status.readName, label: "Finished"),
    ]

    /// Decoded, like every other fixture: the model has no public initialiser.
    /// `locations` nil is a position with no progression at all.
    private func book(locator: [String: Any]?) throws -> Book {
        var json: [String: Any] = [
            "uuid": "u", "title": "A Book", "status": NSNull(),
            "authors": [], "narrators": [], "creators": [], "collections": [],
            "identifiers": [], "tags": [], "series": [],
        ]
        if let locator { json["position"] = ["locator": locator, "timestamp": 0] }
        return try JSONDecoder().decode(
            Book.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func book(at progression: Double) throws -> Book {
        try book(locator: ["href": "a", "type": "t", "locations": ["totalProgression": progression]])
    }

    /// Where the shelf puts the book, and where the write would file it.
    private func bothSides(of subject: Book) throws -> (shelf: LibraryArrangement.Stage, filed: LibraryArrangement.Stage) {
        let locator = try #require(subject.position?.locator)
        let filed = try #require(StatusAdvance.statusToSet(
            after: locator, current: nil, generation: .v3, statuses: statuses))
        return (LibraryArrangement.stage(of: subject), LibraryArrangement.stage(ofStatusNamed: filed.name))
    }

    @Test(
        "every point in the range is shelved where its own position files it",
        arguments: zip(
            [0, 0.001, 0.5, 0.979_999, 0.98, 1],
            [LibraryArrangement.Stage.reading, .reading, .reading, .reading, .finished, .finished]))
    func sweep(progression: Double, expected: LibraryArrangement.Stage) throws {
        let (shelf, filed) = try bothSides(of: book(at: progression))
        #expect(shelf == filed, "the shelf and the write disagree at \(progression)")
        #expect(shelf == expected, "at \(progression)")
    }

    /// The server reads a missing progression as the start, and the start is
    /// "Reading" once a position exists: a bare locator and one whose
    /// `locations` has no `totalProgression` are both being read.
    @Test("a position with no progression is being read, on both sides")
    func missingProgression() throws {
        for subject in [
            try book(locator: ["href": "a", "type": "t"]),
            try book(locator: ["href": "a", "type": "t", "locations": ["progression": 0.4]]),
        ] {
            let (shelf, filed) = try bothSides(of: subject)
            #expect(shelf == filed)
            #expect(shelf == .reading)
        }
    }

    /// The one case the rule never reaches: nothing has been written, so
    /// there is nothing to file and the book is unstarted.
    @Test("a book never opened is unstarted")
    func unopened() throws {
        #expect(LibraryArrangement.stage(of: try book(locator: nil)) == .toRead)
    }

    /// The name half on its own, with the edge a status the server sent with
    /// an empty name sits on.
    @Test("a status is shelved by its name")
    func byName() {
        #expect(LibraryArrangement.stage(ofStatusNamed: Status.toReadName) == .toRead)
        #expect(LibraryArrangement.stage(ofStatusNamed: Status.readingName) == .reading)
        #expect(LibraryArrangement.stage(ofStatusNamed: Status.readName) == .finished)
        #expect(LibraryArrangement.stage(ofStatusNamed: "Currently Reading") == .reading)
        #expect(LibraryArrangement.stage(ofStatusNamed: "Abandoned") == .toRead)
        #expect(LibraryArrangement.stage(ofStatusNamed: "") == .toRead)
    }
}
