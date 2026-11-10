import UIKit
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

    /// Set while a test has Fill the screen on, and cleared once it has turned
    /// it off again. The setting is saved, so a test that stopped on a failure
    /// in between would hand it to every later test in the run.
    private var leftFilling = false

    /// Marks the setting as about to go on, and has the test's teardown turn
    /// it off again if the test stops before it does. A teardown block, not a
    /// `tearDown` override: that is nonisolated, and these helpers are the
    /// main actor's.
    private func turnFillOffIfLeftOn() {
        leftFilling = true
        addTeardownBlock { @MainActor [weak self] in
            guard let self, self.leftFilling else { return }
            self.leftFilling = false
            // From a fresh launch: the failure may have left a sheet up or
            // the reader closed.
            XCUIApplication().terminate()
            let app = self.launch()
            self.openReader(app)
            self.setFill(app, false)
        }
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

    // MARK: Fill the screen with text

    private func fillToggle(_ app: XCUIApplication) -> XCUIElement {
        let toggle = app.descendants(matching: .any)["typography.fillsScreen"].firstMatch
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0 ..< 8 where !toggle.exists || !toggle.isHittable {
            list.swipeUp()
        }
        XCTAssertTrue(toggle.exists, "the Aa sheet has no Fill the screen with text")
        return toggle
    }

    /// Sets the switch, tapping only if it is the other way. The setting is
    /// the book's, and a run's tests share the app's saved state, so a test
    /// cannot assume the one before it left the switch off.
    private func setFill(_ app: XCUIApplication, _ on: Bool) {
        openTypographySheet(app)
        flip(fillToggle(app), on)
        closeSheet(app)
    }

    /// Turns the open sheet's switch on or off, if it is not already.
    private func flip(_ toggle: XCUIElement, _ on: Bool) {
        let want = on ? "1" : "0"
        // A tap while the list is still gliding from the swipe that brought
        // the row up only stops the glide, so let it come to rest, and try
        // again if the switch did not move.
        let set = NSPredicate { _, _ in (toggle.value as? String) == want }
        for _ in 0 ..< 3 where (toggle.value as? String) != want {
            Thread.sleep(forTimeInterval: 0.8)
            // The switch is at the row's trailing edge; the label is not a target.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: set, object: nil)], timeout: 3)
        }
        XCTAssertEqual(toggle.value as? String, want, "the switch did not turn \(on ? "on" : "off")")
    }

    /// Whether the reader's tools stand in a bar across the top, rather than
    /// down a rail beside the page (iPhone Duo): the bar's Back and Aa share
    /// a row, the rail's are stacked. Only a top bar has a band to give.
    private func toolsInATopBar(_ app: XCUIApplication) -> Bool {
        let aa = app.buttons["Text options for this book"].firstMatch
        if !aa.waitForExistence(timeout: 3) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(aa.waitForExistence(timeout: 10), "the reader's tools never showed")
        }
        let back = app.buttons["Back to the book"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no Back button with the tools")
        return abs(back.frame.midY - aa.frame.midY) < 10
    }

    /// The text frame once it has stopped moving: the page re-flows a moment
    /// after the sheet's change, and a frame read before then is the old one.
    private func settledTextFrame(_ app: XCUIApplication, differentFrom old: CGRect? = nil) -> CGRect {
        let probe = app.descendants(matching: .any)["probe.reader.textFrame"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "no text frame probe: is this the fixture build?")
        var last = probe.frame
        var steady = 0
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.4)
            let now = probe.frame
            steady = now == last ? steady + 1 : 0
            last = now
            if steady >= 3, old == nil || now != old { break }
        }
        return last
    }

    /// How far the text's top moves up, and its bottom down, when Fill the
    /// screen goes on at the shipped 24-point margin (the vertical margin
    /// following it), worked out from `ReaderChrome`'s rules.
    ///
    /// - A top bar's band is 44 and stands in for the margin, so off the top
    ///   moves up by 44 - 24 and the bottom gains the footer's 44, where the
    ///   safe areas stay whole: the iPad, and any phone with a rail beside
    ///   the page (iPhone Duo: no top band, only the footer's).
    /// - An upright iPhone with a sensor housing and a home indicator also
    ///   gets part of each safe area back. On the iPhone 17 Pro (402 by 874,
    ///   safe areas 62 and 34) the top keeps 53.6 for the island (0.8 of the
    ///   safe top, plus 4) instead of 62, and the bottom keeps the indicator's
    ///   18 instead of 34 (the corner at a 24-point margin needs only about
    ///   14.5): the top then gains 8.4 more, 28.4 in all, and the bottom 16
    ///   more, 60 in all.
    private func expectedFillDeltas(window: CGRect, topBar: Bool) throws -> (top: CGFloat, bottom: CGFloat) {
        guard topBar else { return (0, 44) }
        if UIDevice.current.userInterfaceIdiom == .pad { return (20, 44) }
        // A home-button phone (the SE, 375×667) has no sensor or indicator
        // to come closer to: only the bars' bands come back.
        if abs(window.width - 375) < 1, abs(window.height - 667) < 1 { return (20, 44) }
        // The 17 Pro and Pro Max share their insets (62 and 34), so the same
        // reclaim as above applies to both.
        let islandPhones = [CGSize(width: 402, height: 874), CGSize(width: 440, height: 956)]
        guard islandPhones.contains(where: { abs($0.width - window.width) < 1 && abs($0.height - window.height) < 1 }) else {
            throw XCTSkip("the expected deltas are worked out for the SE, 17 Pro and Pro Max, not \(window.size)")
        }
        return (28.4, 60)
    }

    /// With the setting on, the text runs into both bars' bands, the controls
    /// are drawn over it, and showing or hiding them moves nothing — nor does
    /// the hidden footer take the taps the last lines are owed.
    func testFillTheScreenGivesBothBandsToTheTextAndKeepsThePageStill() throws {
        let app = launch()
        openReader(app)
        let topBar = toolsInATopBar(app)
        // One visit to the sheet: the page stays live behind it, so the frame
        // before is read with the sheet up, after making sure an earlier test
        // did not leave the setting on.
        openTypographySheet(app)
        let toggle = fillToggle(app)
        flip(toggle, false)
        let before = settledTextFrame(app)
        turnFillOffIfLeftOn()
        flip(toggle, true)
        closeSheet(app)

        let filled = settledTextFrame(app, differentFrom: before)
        let expected = try expectedFillDeltas(window: app.windows.firstMatch.frame, topBar: topBar)
        XCTAssertEqual(
            before.minY - filled.minY, expected.top, accuracy: 1.5,
            "the text did not take the top bar's band, or moved without one: \(before) then \(filled)")
        XCTAssertEqual(
            filled.maxY - before.maxY, expected.bottom, accuracy: 1.5,
            "the text did not move down into the footer's band: \(before) then \(filled)")
        XCTAssertEqual(filled.minX, before.minX, accuracy: 1.5)
        XCTAssertEqual(filled.width, before.width, accuracy: 1.5)

        // The controls over the text, kept for the contact sheet.
        XCTAssertTrue(
            app.buttons["Text options for this book"].firstMatch.waitForExistence(timeout: 5),
            "the controls are not showing")
        keep(app, "fill-the-screen-chrome-over-text")

        // Hiding and showing them leaves the page where it is.
        let window = app.windows.firstMatch
        let middle = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.tap()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(
            app.windows.firstMatch.frame, window.frame)
        let hidden = settledTextFrame(app)
        XCTAssertEqual(hidden, filled, "hiding the controls moved the text")
        keep(app, "fill-the-screen-chrome-hidden")

        // With them hidden, the footer's band is the page's: a tap on its
        // middle is the page's middle tap, and brings the controls back.
        let overFooter = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: (window.frame.height - 60) / window.frame.height))
        overFooter.tap()
        XCTAssertTrue(
            app.buttons["Text options for this book"].firstMatch.waitForExistence(timeout: 5),
            "a tap over the hidden footer's band did not reach the page")
        XCTAssertEqual(settledTextFrame(app), filled, "showing the controls moved the text")

        // And the setting survives closing the book and opening it again.
        let back = app.buttons["Back to the book"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let read = app.descendants(matching: .any)["action.read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), "no Read action after closing the book")
        read.tap()
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Page ")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 60), "the reader never drew a page again")
        let reopened = settledTextFrame(app)
        XCTAssertEqual(reopened.minY, filled.minY, accuracy: 1.5, "the reopened book forgot the setting")
        XCTAssertEqual(reopened.maxY, filled.maxY, accuracy: 1.5, "the reopened book forgot the setting")
        setFill(app, false)
        leftFilling = false
    }

    /// The Top and bottom slider, in the Aa sheet while Fill the screen is on.
    private func verticalMarginSlider(_ app: XCUIApplication) -> XCUIElement {
        let slider = app.descendants(matching: .any)["typography.verticalMargin"].firstMatch
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0 ..< 8 where !slider.exists || !slider.isHittable {
            list.swipeUp()
        }
        XCTAssertTrue(slider.exists, "the Aa sheet has no Top and bottom control with Fill the screen on")
        return slider
    }

    /// Top and bottom is its own margin: set to 0, the text's top and bottom
    /// move out to the hardware's edges and its sides stay where they were.
    func testTopAndBottomMovesOnlyTheTopAndBottom() throws {
        let app = launch()
        openReader(app)
        openTypographySheet(app)
        let toggle = fillToggle(app)
        flip(toggle, false)
        let before = settledTextFrame(app)
        turnFillOffIfLeftOn()
        flip(toggle, true)
        let filled = settledTextFrame(app, differentFrom: before)

        let slider = verticalMarginSlider(app)
        XCTAssertEqual(slider.label, "Top and bottom")
        XCTAssertEqual(slider.value as? String, "24 points", "it should follow the 24-point side margin")
        slider.adjust(toNormalizedSliderPosition: 0)
        let moved = settledTextFrame(app, differentFrom: filled)
        XCTAssertEqual(slider.value as? String, "0 points")

        // The 24 points of margin at each end are gone: the text's top is
        // 24 higher and its bottom 24 lower, whatever the safe areas give.
        XCTAssertEqual(filled.minY - moved.minY, 24, accuracy: 1.5, "the top did not move out: \(filled) then \(moved)")
        XCTAssertEqual(moved.maxY - filled.maxY, 24, accuracy: 1.5, "the bottom did not move out: \(filled) then \(moved)")
        XCTAssertEqual(moved.minX, filled.minX, accuracy: 1.5, "the left margin moved")
        XCTAssertEqual(moved.maxX, filled.maxX, accuracy: 1.5, "the right margin moved")
        XCTAssertEqual(moved.width, filled.width, accuracy: 1.5)
        keep(app, "top-and-bottom-zero")

        // Put back: the switch off, and the book's own departures cleared so
        // the next test starts from the defaults.
        flip(fillToggle(app), false)
        let reset = app.buttons["Use my defaults"].firstMatch
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0 ..< 8 where !reset.exists || !reset.isHittable { list.swipeUp() }
        if reset.exists, reset.isHittable { reset.tap() }
        closeSheet(app)
        leftFilling = false
    }

    /// The selection's Copy, Highlight and Done sit above the footer, which
    /// with the setting on is drawn over the page's bottom: the capsule was
    /// 24 points up from the page's edge, under the 44-point footer.
    func testFillTheScreenKeepsTheSelectionMenuClearOfTheFooter() throws {
        let app = launch()
        openReader(app)
        turnFillOffIfLeftOn()
        setFill(app, true)
        let text = settledTextFrame(app)

        // The controls are showing, which is how a book opens.
        XCTAssertTrue(
            app.buttons["Text options for this book"].firstMatch.waitForExistence(timeout: 5),
            "the controls are not showing")
        let footer = app.descendants(matching: .any)["probe.reader.footer"].firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 10), "no footer probe: is this the fixture build?")

        // On the text itself, measured from its top. After the sweep's earlier
        // tests the book opens on its second chapter's short first page, whose
        // last line sat a third of the way down; with the setting on the text
        // rose clear of a press there, on every phone. The first line under the
        // chapter's heading is about 100 points down; the heading and the line
        // after it are the fallbacks.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let highlight = app.buttons["Highlight"].firstMatch
        let aa = app.buttons["Text options for this book"].firstMatch
        var spot: XCUICoordinate?
        for depth: CGFloat in [100, 46, 130] where !highlight.exists {
            let here = origin.withOffset(CGVector(dx: text.midX, dy: text.minY + depth))
            here.press(forDuration: 0.9)
            if highlight.waitForExistence(timeout: 4) { spot = here }
        }
        XCTAssertTrue(highlight.exists, "pressing and holding on the page selected nothing")
        // A press that found no text ends as a tap, which hides the controls;
        // this is about the menu while the footer shows, so bring them back
        // and select again where the press did find text.
        if !aa.exists, let spot {
            app.buttons["Done"].firstMatch.tap()
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(aa.waitForExistence(timeout: 5), "the controls did not come back")
            spot.press(forDuration: 0.9)
            XCTAssertTrue(highlight.waitForExistence(timeout: 5), "the second press selected nothing")
        }
        XCTAssertTrue(aa.exists, "the controls hid while selecting")
        // Let the lift settle: the menu eases up with the footer's own fade.
        Thread.sleep(forTimeInterval: 0.6)
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.exists)
        keep(app, "fill-the-screen-selection-menu")
        let footerFrame = footer.frame
        for (name, frame) in [("Highlight", highlight.frame), ("Done", done.frame)] {
            XCTAssertFalse(
                frame.intersects(footerFrame),
                "\(name) \(frame) is under the footer \(footerFrame)")
            XCTAssertLessThanOrEqual(frame.maxY, footerFrame.minY, "\(name) is not above the footer")
        }
        done.tap()
        setFill(app, false)
        leftFilling = false
    }
}
