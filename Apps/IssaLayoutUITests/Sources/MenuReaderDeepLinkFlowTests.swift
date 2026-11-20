import XCTest

/// A link to the book already being read, when that reader was reached
/// through a cover's menu.
///
/// The menu's Read pushes the book's page on top of the screen it came from
/// (`BookRouter`), and the reader opens over that page. The tab's root drops a
/// deep link for the book on screen rather than resetting — a "Currently
/// reading" widget or a Handoff of this very book — but every screen's router
/// took its pushed page down on any link at all, and the reader with it.
///
/// Needs the read-along fixture planted under the book's name and the link
/// watcher running, as `scripts/layout-sweep.sh` arranges.
@MainActor
final class MenuReaderDeepLinkFlowTests: XCTestCase {
    private static let readalongUUID = "11111111-1111-4111-8111-111111111111"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        removeLinkFlag()
    }

    override func tearDown() {
        removeLinkFlag()
        super.tearDown()
    }

    func testLinkToTheOpenBookLeavesItsReaderUp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-IssaUITestFixture", "-issa.library.mode", "all"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["card.continue"].waitForExistence(timeout: 120),
                      "the fixture's catalogue never arrived")

        let inBar = app.tabBars.buttons["Library"].firstMatch
        (inBar.exists ? inBar : app.buttons["Library"].firstMatch).tap()
        let search = app.textFields["Title, author, narrator, series, tag"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "no library search field")
        search.tap()
        search.typeText("Peter and Wendy\n")
        let cell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                  "cell.book.", "Peter and Wendy"))
            .firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "the read-along book is not on the shelf")

        // Read, from the cover's menu.
        cell.press(forDuration: 1.2)
        let read = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Read", "Resume"))
            .firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 10), "the menu offered no Read")
        read.tap()

        let coach = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                                  "Reading gestures", "This book is narrated"))
            .firstMatch
        if coach.waitForExistence(timeout: 20) {
            coach.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let reader = app.descendants(matching: .any)["screen.reader"]
        XCTAssertTrue(reader.waitForExistence(timeout: 60),
                      "the reader never opened: is the planted EPUB on disk under this book's name?")

        // The widget's link to the book being read, sent to the running app:
        // `XCUIApplication.open` relaunches it, which tests nothing about a
        // link finding a reader already up.
        let probe = app.descendants(matching: .any)["probe.link"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "the fixture build has no link probe")
        let before = probe.value as? String
        try deliverLink(toBook: Self.readalongUUID)

        // Positive evidence first: the app saw this link and decided to leave
        // the reader as it was. Without it the check below passes when the
        // link never reached the app.
        let left = NSPredicate { _, _ in
            let value = probe.value as? String ?? ""
            return value != before && value.hasSuffix(":leave:\(Self.readalongUUID)")
        }
        let decided = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: left, object: nil)], timeout: 30)
        XCTAssertEqual(decided, .completed,
                       "the app never decided to leave the reader up for this link: it read \(probe.value as? String ?? "nothing")")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(reader.exists, "a link to the book being read closed its reader")
    }
}
