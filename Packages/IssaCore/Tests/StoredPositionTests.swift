import Foundation
import Testing

@testable import IssaCore

/// Keeping the library's copy of a reading position in step with the reader.
///
/// The Continue card, the library row and the book screen all read
/// `book.progress`, and it used to move only when the book was fetched again —
/// so it could sit a whole reading session behind. The app writes the locator
/// itself, so it can simply adopt it; these are the rules for doing that
/// safely.
@Suite("Adopting a reading position")
struct StoredPositionTests {
    func book(progress: Double? = nil, timestamp: Double = 0) -> Book {
        var json: [String: Any] = [
            "uuid": "u", "title": "A Book",
            "authors": [], "narrators": [], "creators": [], "series": [],
            "collections": [], "identifiers": [], "tags": [],
        ]
        if let progress {
            json["position"] = [
                "uuid": "p",
                "locator": ["href": "a", "type": "t",
                            "locations": ["totalProgression": progress]],
                "timestamp": timestamp,
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    func locator(_ progression: Double) -> ReadiumLocator {
        ReadiumLocator(
            href: "a", type: "t",
            locations: .init(progression: progression, totalProgression: progression),
        )
    }

    @Test("a book that has never been opened takes the position")
    func adoptsFirstPosition() {
        var subject = book()
        subject.adopt(position: locator(0.22), timestamp: 100)
        #expect(subject.progress == 0.22)
    }

    @Test("reading on moves the position forward")
    func adoptsNewerPosition() {
        var subject = book(progress: 0.13, timestamp: 100)
        subject.adopt(position: locator(0.22), timestamp: 200)
        #expect(subject.progress == 0.22)
    }

    /// The failure this exists for. The mutation queue drains asynchronously,
    /// so an earlier page can be written after a later one; without the check
    /// the reader watches their own progress retreat.
    @Test("a save that arrives out of order does not move the reader back")
    func refusesOlderPosition() {
        var subject = book(progress: 0.22, timestamp: 200)
        subject.adopt(position: locator(0.13), timestamp: 100)
        #expect(subject.progress == 0.22, "an older write moved the position backwards")
    }

    /// Equal timestamps are the same save, or a re-save of the same page: the
    /// newer locator wins, which matches how the server resolves the tie.
    @Test("an equal timestamp adopts the new locator")
    func adoptsAtEqualTimestamp() {
        var subject = book(progress: 0.22, timestamp: 200)
        subject.adopt(position: locator(0.30), timestamp: 200)
        #expect(subject.progress == 0.30)
    }

    @Test("adopting keeps the server's identity for the row")
    func keepsPositionUUID() {
        var subject = book(progress: 0.13, timestamp: 100)
        subject.adopt(position: locator(0.22), timestamp: 200)
        #expect(subject.position?.uuid == "p", "a new uuid would create a second row on the server")
    }

    // MARK: - Reconciling a catalogue refresh

    /// The library is refetched wholesale, and a refetch that predates a write
    /// still in the mutation queue carries a stale position. Assigning it
    /// verbatim walks the reader backwards.
    @Test("a catalogue refresh that predates our own write does not undo it")
    func refreshDoesNotUndoOurWrite() {
        let mine = book(progress: 0.62, timestamp: 200)
        let fresh = book(progress: 0.31, timestamp: 100)
        #expect(mine.reconciled(with: fresh).progress == 0.62)
    }

    @Test("a refresh that is ahead of us wins, because another device moved")
    func refreshFromAnotherDeviceWins() {
        let mine = book(progress: 0.62, timestamp: 200)
        let fresh = book(progress: 0.71, timestamp: 300)
        #expect(mine.reconciled(with: fresh).progress == 0.71)
    }

    /// Guards the degenerate implementation that just returns `self` and so
    /// never takes any server news at all.
    @Test("a refresh brings everything about the book except where we are")
    func refreshBringsEverythingElse() {
        var mine = book(progress: 0.62, timestamp: 200)
        mine.title = "Stale Title"
        var fresh = book(progress: 0.31, timestamp: 100)
        fresh.title = "The Real Title"
        let merged = mine.reconciled(with: fresh)
        #expect(merged.title == "The Real Title", "the catalogue is newer for everything else")
        #expect(merged.progress == 0.62, "except our own place in it")
    }

    @Test("a server that has never heard of our position does not clear it")
    func refreshWithNoPositionKeepsOurs() {
        let mine = book(progress: 0.62, timestamp: 200)
        #expect(mine.reconciled(with: book()).progress == 0.62)
    }

    @Test("a book we have never opened takes whatever the refresh says")
    func refreshWinsWhenWeHaveNothing() {
        #expect(book().reconciled(with: book(progress: 0.4, timestamp: 100)).progress == 0.4)
    }

    /// Both halves of the reported bug, together: the reader's own footer and
    /// every other surface now read from one number *and* one formatter.
    @Test("the library agrees with the reader once the position is adopted")
    func agreesWithTheReader() {
        var subject = book(progress: 0.13, timestamp: 100)
        subject.adopt(position: locator(0.137), timestamp: 200)
        #expect(ReadingProgress.percentText(subject.progress ?? 0) == "14%")
    }
}
