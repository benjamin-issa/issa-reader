import Foundation
import Testing

@testable import IssaCore

/// Keeping a status this device set through a catalogue refresh.
///
/// The app decides whether a status is still unsent; `reconciled(with:
/// keepingStatus:)` is the one place that answer is applied, so the catalogue
/// refresh and the single-book refresh cannot apply it two different ways, as
/// their hand-written copies could. It has to act before the position rule's
/// early return: a book with no position of its own can still carry a status
/// the reader set from its detail screen.
@Suite("Keeping an unsent status through a refresh")
struct ReconcileStatusTests {
    /// Decoded, like every other fixture: the model has no public initialiser.
    private func book(status: String?, progress: Double? = nil, timestamp: Double = 0) throws -> Book {
        var json: [String: Any] = [
            "uuid": "u", "title": "A Book",
            "authors": [], "narrators": [], "creators": [], "series": [],
            "collections": [], "identifiers": [], "tags": [],
        ]
        json["status"] = status.map { ["uuid": "s-\($0)", "name": $0] } ?? NSNull()
        if let progress {
            json["position"] = [
                "locator": ["href": "a", "type": "t", "locations": ["totalProgression": progress]],
                "timestamp": timestamp,
            ]
        }
        return try JSONDecoder().decode(
            Book.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("a kept status survives a refresh that says otherwise, beside a newer position")
    func keptWithAPosition() throws {
        let mine = try book(status: Status.readName, progress: 0.62, timestamp: 200)
        let fresh = try book(status: nil, progress: 0.31, timestamp: 100)
        let merged = mine.reconciled(with: fresh, keepingStatus: true)
        #expect(merged.status?.name == Status.readName)
        #expect(merged.progress == 0.62, "the position rule still applies")
    }

    /// The case the early return would lose: a book never opened here, filed
    /// from its detail screen. It has no position of its own, and the status
    /// must still be kept.
    @Test("a kept status survives on a book with no position of its own")
    func keptWithoutAPosition() throws {
        let mine = try book(status: Status.readName)
        let fresh = try book(status: nil, progress: 0.4, timestamp: 100)
        let merged = mine.reconciled(with: fresh, keepingStatus: true)
        #expect(merged.status?.name == Status.readName, "the status was dropped with no position to keep")
        #expect(merged.progress == 0.4, "the server's position is taken as given")
    }

    /// Nothing unsent: the server's status is newer truth, and the single-
    /// argument form every existing caller uses is unchanged.
    @Test("without it, the server's status is taken, position or not")
    func serverStatusByDefault() throws {
        let fresh = try book(status: Status.readingName, progress: 0.31, timestamp: 100)
        for mine in [
            try book(status: Status.readName, progress: 0.62, timestamp: 200),
            try book(status: Status.readName),
        ] {
            #expect(mine.reconciled(with: fresh).status?.name == Status.readingName)
            #expect(mine.reconciled(with: fresh, keepingStatus: false).status?.name == Status.readingName)
        }
    }
}
