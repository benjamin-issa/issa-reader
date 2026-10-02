import XCTest

/// A book's hold menu, driven on a real device.
///
/// The menu's contents are decided by `BookMenu` and tested there; what only a
/// device can show is that a long press on each surface opens it, and that its
/// items take the reader where they say — a push on top of the screen the menu
/// came from, with Back returning to it.
///
/// Written against the fixture library: six books, one download planted per
/// book except the read-along, and "Dracula" in a two-book series.
@MainActor
final class BookMenuFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-IssaUITestFixture"] + extraArguments
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["card.continue"].waitForExistence(timeout: 120),
            "the fixture's catalogue never arrived")
        return app
    }

    /// At the largest text sizes the element can start below the fold, where a
    /// long press has nothing to land on.
    private func bringIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        let scroller = app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app.collectionViews.firstMatch
        for _ in 0 ..< 8 where !element.isHittable {
            scroller.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable, "\(element) never scrolled into view")
    }

    private func openMenu(on element: XCUIElement, in app: XCUIApplication) {
        bringIntoView(element, in: app)
        element.press(forDuration: 1.2)
    }

    private func viewDetails(_ app: XCUIApplication) {
        let item = app.buttons["View details"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the menu offered no View details")
        item.tap()
    }

    private func assertBookPage(showing title: String, in app: XCUIApplication) {
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.bookDetail"].waitForExistence(timeout: 15),
            "View details did not open the book page")
        let heading = app.descendants(matching: .any)["screen.bookDetail"].staticTexts[title]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "the book page is not \(title)'s")
    }

    /// The Continue card's own page, from its menu, and Back to the tab it was
    /// on — the push lands on top of the Reading tab rather than replacing it.
    func testContinueCardViewsDetailsAndComesBack() {
        let app = launch()
        // The chevron beside the card is labelled with the card's book, which
        // is the one title on the card the tests can read without guessing
        // which book the fixture puts there.
        let chevron = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Details for ")).firstMatch
        XCTAssertTrue(chevron.waitForExistence(timeout: 15), "the Continue card has no details chevron")
        let title = String(chevron.label.dropFirst("Details for ".count))

        let card = app.buttons.matching(NSPredicate(format: "label == %@", "Resume \(title)")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no Continue card to hold")
        openMenu(on: card, in: app)
        viewDetails(app)
        assertBookPage(showing: title, in: app)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.reading"].waitForExistence(timeout: 15),
            "Back did not return to the Reading tab")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the Reading tab came back without its card")
    }

    /// An "Also reading" row resumes on a tap, so its menu is the way to the
    /// book's page.
    func testResumeRowViewsDetails() {
        let app = launch()
        let row = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@", "Resume ", "% complete")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no Also reading row")
        let title = row.label
            .dropFirst("Resume ".count)
            .components(separatedBy: ", ").dropLast().joined(separator: ", ")
        openMenu(on: row, in: app)
        viewDetails(app)
        assertBookPage(showing: title, in: app)
    }

    /// A downloaded row's menu is the book's menu with the row's own removal
    /// in it, and its View details reaches the book.
    func testDownloadedRowOffersDetailsAndRemoval() {
        let app = launch()
        let manage = app.buttons["Manage downloads"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 30), "no route to the Downloads screen")
        manage.tap()

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Dracula, "))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no Dracula row")
        openMenu(on: row, in: app)
        XCTAssertTrue(app.buttons["Remove download"].firstMatch.waitForExistence(timeout: 10),
                      "the row's menu lost its removal")
        viewDetails(app)
        assertBookPage(showing: "Dracula", in: app)
    }

    /// A removal from the library grid, which lists no downloads of its own:
    /// the undo has to be offered on the tab the reader is on, and has to work.
    func testGridRemovalOffersUndoOnTheLibraryTab() {
        // The flat grid, not Browse: `libraryMode` is read from UserDefaults,
        // and the argument domain comes first.
        let app = launch(["-issa.library.mode", "all"])
        let library = app.tabBars.buttons["Library"].exists
            ? app.tabBars.buttons["Library"] : app.buttons["Library"].firstMatch
        library.tap()

        let search = app.textFields["Title, author, narrator, series, tag"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "no library search field")
        search.tap()
        search.typeText("Dracula\n")
        let cell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "cell.book.", "Dracula"))
            .firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "no Dracula cell in the grid")
        openMenu(on: cell, in: app)

        let remove = app.buttons["Remove download"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "the menu offered no removal for a downloaded book")
        remove.tap()

        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the Library tab offered no undo")
        XCTAssertTrue(undo.isHittable, "the undo is there but under something")
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5), "Undo did not take the toast down")

        // And the book is still downloaded: its menu offers the removal again.
        openMenu(on: cell, in: app)
        XCTAssertTrue(app.buttons["Remove download"].firstMatch.waitForExistence(timeout: 10),
                      "the undone removal happened anyway")
    }
}
