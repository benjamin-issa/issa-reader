import XCTest

/// The Margins control in a book's Aa sheet: a preset moves the page's text,
/// and the choice is still there when the sheet is opened again.
///
/// On a book that is not the first on the shelf, so that a margin written for
/// "the first book" or for every book would not pass unseen. The reader's
/// text frame is read from `probe.reader.textFrame`, which the fixture build
/// draws over the page's inset box.
///
/// Needs the read-along fixture planted under the book's name, as
/// `scripts/layout-sweep.sh` does.
@MainActor
final class MarginControlFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-IssaUITestFixture", "-issa.library.mode", "all"]
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["card.continue"].waitForExistence(timeout: 120),
            "the fixture's catalogue never arrived")
        return app
    }

    /// Opens the read-along book from the shelf — whichever row it is on, and
    /// the test says which — and waits for a page.
    private func openReader(_ app: XCUIApplication) {
        let inBar = app.tabBars.buttons["Library"].firstMatch
        (inBar.exists ? inBar : app.buttons["Library"].firstMatch).tap()
        let cells = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "cell.book."))
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 15), "no books on the shelf")
        let book = cells
            .matching(NSPredicate(format: "label CONTAINS %@", "Peter and Wendy")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15), "the read-along book is not on the shelf")
        XCTAssertNotEqual(
            cells.firstMatch.identifier, book.identifier,
            "the read-along book is the first on the shelf: this test needs one that is not")
        book.tap()
        let read = app.descendants(matching: .any)["action.read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), "no Read action on the book screen")
        read.tap()
        let coach = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                "Reading gestures", "This book is narrated"))
            .firstMatch
        if coach.waitForExistence(timeout: 20) {
            coach.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Page "))
            .firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 60), "the reader never drew a page")
    }

    private func openTypographySheet(_ app: XCUIApplication) {
        let aa = app.buttons["Text options for this book"].firstMatch
        if !aa.waitForExistence(timeout: 3) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(aa.waitForExistence(timeout: 10), "the reader's tools never showed")
        }
        aa.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["typography.margins"].waitForExistence(timeout: 15)
                || scrollToMargins(app),
            "the Aa sheet has no Margins control")
    }

    /// The sheet stops half way up, so the control may be below the fold.
    private func scrollToMargins(_ app: XCUIApplication) -> Bool {
        let slider = app.descendants(matching: .any)["typography.margins"].firstMatch
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0 ..< 8 where !slider.exists || !slider.isHittable {
            list.swipeUp()
        }
        return slider.exists
    }

    private func tapPreset(_ app: XCUIApplication, _ name: String) {
        let button = app.buttons["typography.margins.\(name)"].firstMatch
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0 ..< 8 where !button.exists || !button.isHittable {
            list.swipeUp()
        }
        XCTAssertTrue(button.isHittable, "the \(name) preset cannot be reached")
        button.tap()
    }

    private func closeSheet(_ app: XCUIApplication) {
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the Aa sheet has no Done")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10), "the Aa sheet did not close")
    }

    /// The text's frame once the reader has settled on it: the probe moves
    /// when the page re-flows, a moment after the sheet's change.
    private func textFrame(_ app: XCUIApplication, minX expected: CGFloat) -> CGRect {
        let probe = app.descendants(matching: .any)["probe.reader.textFrame"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "no text frame probe: is this the fixture build?")
        let settled = NSPredicate { _, _ in abs(probe.frame.minX - expected) < 1.5 }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 10)
        return probe.frame
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testPresetsMoveThePageTextAndSurviveReopening() throws {
        let app = launch()
        openReader(app)
        let window = app.windows.firstMatch.frame

        // Edge: the text is 4 points from each side.
        openTypographySheet(app)
        tapPreset(app, "edge")
        let slider = app.descendants(matching: .any)["typography.margins"].firstMatch
        XCTAssertEqual(slider.label, "Margins")
        XCTAssertEqual(slider.value as? String, "4 points")
        closeSheet(app)
        let edge = textFrame(app, minX: 4)
        XCTAssertEqual(edge.minX, 4, accuracy: 1.5, "Edge did not move the text to 4 points: \(edge)")
        XCTAssertEqual(window.maxX - edge.maxX, 4, accuracy: 1.5, "Edge is not the same on the right: \(edge)")

        // Wide: 48, and the column narrower by the difference.
        openTypographySheet(app)
        tapPreset(app, "wide")
        XCTAssertEqual(slider.value as? String, "48 points")
        // What no query can see: the bands' colour and where they stand over
        // the page, kept for a look at the contact sheet.
        keep(app, "margins-wide-bands")
        closeSheet(app)
        let wide = textFrame(app, minX: 48)
        XCTAssertEqual(wide.minX, 48, accuracy: 1.5, "Wide did not move the text to 48 points: \(wide)")
        XCTAssertEqual(
            edge.width - wide.width, 88, accuracy: 3,
            "the column did not narrow by the 44 points each side gained: \(edge) then \(wide)")

        // And the choice is there when the sheet is opened again.
        openTypographySheet(app)
        XCTAssertEqual(slider.value as? String, "48 points", "the sheet forgot the margin")
        let selected = app.buttons["typography.margins.wide"].firstMatch
        XCTAssertTrue(selected.isSelected, "Wide is not shown selected")
        XCTAssertFalse(app.buttons["typography.margins.edge"].firstMatch.isSelected)
        closeSheet(app)
        XCTAssertEqual(textFrame(app, minX: 48).minX, 48, accuracy: 1.5)
    }
}
