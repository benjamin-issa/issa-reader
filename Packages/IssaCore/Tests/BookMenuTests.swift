import Foundation
import Testing

@testable import IssaCore

/// The hold / right-click menu every book surface shares.
///
/// Each case is something the menu can get quietly wrong while still drawing:
/// an item that leads nowhere, or the way to the page the reader is already on.
@Suite("A book's menu")
struct BookMenuTests {
    private func book(
        uuid: String = "u",
        status: String? = nil,
        progress: Double? = nil,
        ebook: Bool = true,
        audiobook: Bool = false,
        readaloud: Bool = false,
        ebookMissing: Bool = false,
        authors: [String] = ["Bram Stoker"],
        series: [(name: String, position: Double?)] = [],
    ) -> Book {
        var json: [String: Any] = [
            "uuid": uuid, "title": "A Book",
            "authors": authors.map { ["uuid": $0, "name": $0] },
            "narrators": [], "creators": [], "collections": [], "identifiers": [], "tags": [],
            "series": series.map { membership -> [String: Any] in
                var row: [String: Any] = ["uuid": membership.name, "name": membership.name]
                if let position = membership.position { row["position"] = position }
                return row
            },
        ]
        if ebook { json["ebook"] = ["uuid": "e", "identifiers": [], "missing": ebookMissing] }
        if audiobook { json["audiobook"] = ["uuid": "a", "filepath": "a.m4b", "identifiers": []] }
        if readaloud {
            json["readaloud"] = [
                "uuid": "r", "filepath": "r.epub", "status": "ALIGNED", "identifiers": [],
            ]
        }
        if let status { json["status"] = ["uuid": status, "name": status] }
        if let progress {
            json["position"] = [
                "locator": ["href": "a", "type": "t", "locations": ["totalProgression": progress]],
                "timestamp": 0,
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    private func status(_ name: String) -> Status {
        Status(uuid: name, name: name)
    }

    private func menu(_ book: Book, _ inputs: BookMenu.Inputs = .init()) -> BookMenu {
        BookMenu.resolve(for: book, inputs: inputs)
    }

    // MARK: - Opening the book

    @Test("the first group is View details, Read, Listen, in that order")
    func openingOrder() {
        let subject = menu(book(readaloud: true))
        #expect(subject.sections.first == [.details, .read(title: "Read"), .listen])
    }

    @Test("an audiobook-only book has no Read, because there is no text to open")
    func audiobookOnlyHasNoRead() {
        let items = menu(book(ebook: false, audiobook: true)).items
        #expect(!items.contains { if case .read = $0 { true } else { false } })
        #expect(items.contains(.listen))
    }

    @Test("a book with a place to return to says Resume, as the book page does")
    func resumeWhenStarted() {
        #expect(menu(book(progress: 0.4)).items.contains(.read(title: "Resume")))
    }

    @Test("Listen is offered for a read-along and for an audiobook, and for neither on a plain ebook")
    func listenNeedsAudio() {
        #expect(menu(book(readaloud: true)).items.contains(.listen))
        #expect(menu(book(audiobook: true)).items.contains(.listen))
        #expect(!menu(book()).items.contains(.listen))
    }

    @Test("Listen becomes Now Playing while this book is the one playing")
    func nowPlaying() {
        let items = menu(book(audiobook: true), .init(isPlaying: true)).items
        #expect(items.contains(.nowPlaying))
        #expect(!items.contains(.listen))
    }

    // MARK: - Status and rating

    @Test("no statuses from the server means no Mark as")
    func noStatusesNoMarkAs() {
        #expect(!menu(book()).items.contains { if case .markAs = $0 { true } else { false } })
    }

    @Test("Mark as lists every status in the server's order with the book's own marked")
    func markAsMarksCurrent() throws {
        let statuses = ["To read", "Reading", "Read"].map(status)
        let items = menu(book(status: "Reading"), .init(statuses: statuses)).items
        let choices = try #require(items.compactMap { item -> [BookMenu.StatusChoice]? in
            if case let .markAs(choices) = item { choices } else { nil }
        }.first)
        #expect(choices.map(\.status.name) == ["To read", "Reading", "Read"])
        #expect(choices.map(\.isCurrent) == [false, true, false])
    }

    @Test("Rate carries the current rating, so Clear rating appears only when there is one")
    func rateCarriesRating() {
        #expect(menu(book()).items.contains(.rate(current: nil)))
        #expect(menu(book(), .init(rating: 4)).items.contains(.rate(current: 4)))
    }

    /// R-07. The rating is the server's number, decoded as any `Double`, and
    /// `Int(1e300)` is not a wrong answer but a trap — every time the book's
    /// hold menu was built, and on tvOS that menu is the only rating surface.
    /// The book page learned this in 1.3.0; the shared menu had to as well.
    @Test("a rating far outside five stars is clamped, not a crash", arguments: [
        (1e300, 5), (-1e300, 0), (7.6, 5), (-2, 0), (3.4, 3),
    ])
    func absurdRatingIsClamped(rating: Double, stars: Int) {
        #expect(menu(book(), .init(rating: rating)).items.contains(.rate(current: stars)))
    }

    // MARK: - Editions

    @Test("each edition's one action follows its download state")
    func editionActionFollowsState() {
        #expect(BookMenu.kind(state: nil, onDisk: false) == .save)
        #expect(BookMenu.kind(state: .queued, onDisk: false) == .pause)
        #expect(BookMenu.kind(
            state: .downloading(fractionCompleted: 0.5, bytesWritten: 5, totalBytes: 10),
            onDisk: false) == .pause)
        #expect(BookMenu.kind(state: .paused(fractionCompleted: 0.5), onDisk: false) == .resume)
        #expect(BookMenu.kind(state: .failed("nope"), onDisk: false) == .retry)
        #expect(BookMenu.kind(state: nil, onDisk: true) == .remove)
        // A good file and a failed re-download: the file wins, as on the page.
        #expect(BookMenu.kind(state: .failed("nope"), onDisk: true) == .remove)
    }

    @Test("one edition is drawn inline; several go behind a Downloads submenu")
    func inlineOrSubmenu() {
        let single = menu(book()).items
        #expect(single.contains(.edition(.init(format: .ebook, kind: .save))))

        let several = menu(book(audiobook: true, readaloud: true),
                           .init(downloadedFormats: [.readaloud])).items
        #expect(several.contains(.downloads([
            .init(format: .ebook, kind: .save),
            .init(format: .audiobook, kind: .save),
            .init(format: .readaloud, kind: .remove),
        ])))
    }

    @Test("an edition the server has lost gets no action")
    func lostEditionGetsNothing() {
        let items = menu(book(audiobook: true, ebookMissing: true)).items
        #expect(items.contains(.edition(.init(format: .audiobook, kind: .save))))
        #expect(!items.contains { if case .downloads = $0 { true } else { false } })
    }

    @Test("a Downloads row's own removal comes last and is not repeated among the editions")
    func focusedRemovalIsLast() throws {
        let subject = menu(book(readaloud: true), .init(
            downloadedFormats: [.ebook, .readaloud], focusEdition: .ebook))
        #expect(subject.sections.last == [.removeFocused(.ebook)])
        // The other edition stays, inline now that it is the only one left.
        #expect(subject.items.contains(.edition(.init(format: .readaloud, kind: .remove))))
        #expect(!subject.items.contains(.edition(.init(format: .ebook, kind: .remove))))
    }

    // MARK: - Series and author

    @Test("Go to Series follows the library's grouping: a series of one has no page")
    func seriesNeedsAGroup() {
        let inSeries = book(series: [(name: "Gothic Horror", position: 1)])
        #expect(menu(inSeries, .init(groupedSeries: ["Gothic Horror"])).items
            .contains(.goToSeries(name: "Gothic Horror")))
        #expect(!menu(inSeries, .init(groupedSeries: [])).items
            .contains(.goToSeries(name: "Gothic Horror")))
    }

    @Test("Go to Series names the numbered membership, as the cover badge does")
    func seriesIsThePrimaryOne() {
        let omnibus = book(series: [(name: "Shelf", position: nil), (name: "Gothic Horror", position: 2)])
        #expect(menu(omnibus, .init(groupedSeries: ["Shelf", "Gothic Horror"])).items
            .contains(.goToSeries(name: "Gothic Horror")))
    }

    @Test("Go to Series is hidden on that series' own page")
    func seriesHiddenOnItsPage() {
        let inSeries = book(series: [(name: "Gothic Horror", position: 1)])
        #expect(!menu(inSeries, .init(groupedSeries: ["Gothic Horror"], place: .series("Gothic Horror")))
            .items.contains(.goToSeries(name: "Gothic Horror")))
    }

    @Test("More by needs another book by the author, and is hidden on the author's own page")
    func moreByRules() {
        let subject = book()
        #expect(!menu(subject, .init(firstAuthorBookCount: 1)).items.contains(.moreBy(author: "Bram Stoker")))
        #expect(menu(subject, .init(firstAuthorBookCount: 2)).items.contains(.moreBy(author: "Bram Stoker")))
        #expect(!menu(subject, .init(firstAuthorBookCount: 2, place: .author("Bram Stoker")))
            .items.contains(.moreBy(author: "Bram Stoker")))
    }

    // MARK: - Platforms

    @Test("the television keeps Mark as, Rate and the editions, and nothing that leads off its one screen")
    func television() {
        let subject = menu(book(audiobook: true, series: [(name: "Gothic Horror", position: 1)]), .init(
            statuses: [status("Reading")], groupedSeries: ["Gothic Horror"],
            firstAuthorBookCount: 3, capabilities: .television))
        for item in subject.items {
            switch item {
            case .markAs, .rate, .edition, .downloads: continue
            default: Issue.record("the television offered \(item)")
            }
        }
        #expect(subject.items.contains { if case .markAs = $0 { true } else { false } })
    }

    @Test("the Mac's Settings window keeps details and reading but cannot push a page")
    func settingsWindow() {
        let items = menu(book(series: [(name: "Gothic Horror", position: 1)]), .init(
            groupedSeries: ["Gothic Horror"], firstAuthorBookCount: 3,
            capabilities: .settingsWindow)).items
        #expect(items.contains(.details))
        #expect(!items.contains(.goToSeries(name: "Gothic Horror")))
        #expect(!items.contains(.moreBy(author: "Bram Stoker")))
    }

    @Test("signed out, only removing a file on this device is offered")
    func signedOut() {
        let subject = menu(book(readaloud: true), .init(
            isSignedIn: false, statuses: [status("Reading")],
            downloadedFormats: [.ebook, .readaloud], focusEdition: .readaloud))
        #expect(subject.sections == [
            [.edition(.init(format: .ebook, kind: .remove))],
            [.removeFocused(.readaloud)],
        ])
        #expect(menu(book(), .init(isSignedIn: false)).isEmpty)
    }

    @Test("an edition's words name the edition only inside the submenu")
    func editionTitles() {
        let action = BookMenu.EditionAction(format: .readaloud, kind: .save)
        #expect(action.title(namingEdition: false) == "Save for offline")
        #expect(action.title(namingEdition: true) == "Save Read-along for offline")
        #expect(BookMenu.EditionAction(format: .ebook, kind: .remove).isDestructive)
    }
}
