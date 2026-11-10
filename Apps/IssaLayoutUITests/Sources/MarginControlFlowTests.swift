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
        // On iOS 27.1 the half-height sheet's bar goes away while its rows are
        // scrolled down, title and Done with it, and comes back at the top —
        // so, as a reader would, scroll back up before looking for it.
        if !done.waitForExistence(timeout: 3) {
            let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
            for _ in 0 ..< 6 where !done.exists { list.swipeDown() }
        }
        if !done.waitForExistence(timeout: 10) { keep(app, "aa-sheet-without-done") }
        XCTAssertTrue(done.exists, "the Aa sheet has no Done, even scrolled back to its top")
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

    /// Whether a point of the screen (in points) carries the bands' tangerine
    /// tint over the paper page: paper is near white with red and blue within
    /// a few levels of each other, black text has them equal, and tangerine at
    /// 14% over paper leaves red some 30 levels above blue.
    private func isTinted(_ shot: XCUIScreenshot, x: CGFloat, y: CGFloat) -> Bool {
        guard let image = shot.image.cgImage else { return false }
        let scale = CGFloat(image.width) / shot.image.size.width
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.translateBy(x: -x * scale, y: -(CGFloat(image.height) - y * scale))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let red = Int(pixel[0]), blue = Int(pixel[2])
        return red > 200 && red - blue > 15
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
        // From the page's own right edge, not the window's: on iPhone Duo's
        // outer display the page stops at the rail.
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Page ")).firstMatch.frame
        XCTAssertEqual(page.maxX - edge.maxX, 4, accuracy: 1.5, "Edge is not the same on the right: \(edge) in \(page)")

        // Wide: 48, and the column narrower by the difference.
        openTypographySheet(app)
        tapPreset(app, "wide")
        // What no query can see: the bands' colour and where they stand. Taken
        // at once, while they linger after the tap, and kept for the contact
        // sheet. Each margin is tinted halfway across it, above the half-height
        // sheet: in 1.7.0's first build the bands stood in the middle of the
        // text, and the geometry's unit test could not tell.
        let shot = app.screenshot()
        keep(app, "margins-wide-bands")
        let y = window.minY + window.height * 0.3
        XCTAssertTrue(isTinted(shot, x: window.minX + 24, y: y), "no band in the left margin")
        let pageRight = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Page ")).firstMatch.frame.maxX
        XCTAssertTrue(isTinted(shot, x: pageRight - 24, y: y), "no band in the right margin")
        XCTAssertEqual(slider.value as? String, "48 points")
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

    /// The Aa sheet leaves the page behind it live, and the top bar with it
    /// used to be: a tap on Contents, Find or Marks set the flag for a sheet
    /// of its own, SwiftUI could only present one, and that one came up
    /// unbidden when the Aa sheet closed.
    func testTopBarTakesNoTouchesBehindTheHalfHeightSheet() throws {
        let app = launch()
        openReader(app)
        openTypographySheet(app)
        var tapped = 0
        for id in ["reader.contents", "reader.find", "reader.marks", "reader.ask"] {
            let button = app.descendants(matching: .any)[id].firstMatch
            guard button.exists else { continue }   // folded into the menu on a narrow bar
            // Not `isHittable`: XCUITest answers that from where the element
            // is on screen, and `allowsHitTesting(false)` does not change it.
            // What matters is what a touch does, so touch it and look.
            // A real touch at the button, which hit-testing must swallow.
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            tapped += 1
        }
        XCTAssertGreaterThan(tapped, 0, "none of the top bar's buttons were found")
        closeSheet(app)
        // Give a queued sheet the moment it would need to come up.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(
            app.buttons["Done"].firstMatch.exists,
            "a sheet that a tap behind the Aa sheet asked for came up when it closed")
        // And the bar works again once the sheet is gone.
        let contents = app.descendants(matching: .any)["reader.contents"].firstMatch
        if contents.exists { XCTAssertTrue(contents.isHittable) }
    }
}
