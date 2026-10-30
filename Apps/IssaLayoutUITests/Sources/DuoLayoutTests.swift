import XCTest

/// iPhone Duo's outer display: the reader's tools in a rail down the side, the
/// page clear of it, and the shelf three covers across (1.6.0).
///
/// Measured against what the system tells the app — the unsafe band down the
/// side, the sensor bar's region — which the fixture build publishes
/// (`DuoProbe`), not against numbers written here. The inner display cannot
/// be reached from the command line (see CLAUDE.md); it is checked by hand.
///
/// In the same target as the sweep, so it runs on every sweep device and skips
/// everywhere but the Duo's outer display.
@MainActor
final class DuoLayoutTests: XCTestCase {
    private var deviceSlug: String {
        ProcessInfo.processInfo.environment["ISSA_SWEEP_DEVICE"] ?? "device"
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    /// What `probe.duo.<scope>` read: the unsafe band down the trailing side
    /// and the bottom of whatever occludes it.
    private struct Reading {
        let trailing: CGFloat
        let occludedTo: CGFloat
        let raw: String

        init(_ raw: String, window: CGRect) {
            self.raw = raw
            var fields: [String: String] = [:]
            for part in raw.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { fields[pair[0]] = pair[1] }
            }
            let safe = (fields["safe"] ?? "").split(separator: ",").compactMap { Double($0) }
            trailing = safe.count == 4 ? CGFloat(safe[3]) : 0
            let band = CGRect(x: window.maxX - trailing, y: 0, width: trailing, height: window.height)
            occludedTo = (fields["occ"] ?? "").split(separator: "|").compactMap { region -> CGFloat? in
                let values = region.split(separator: ",").compactMap { Double($0) }
                guard values.count == 4 else { return nil }
                let frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                return frame.intersects(band) ? frame.maxY : nil
            }.max() ?? 0
        }
    }

    private func reading(_ app: XCUIApplication, _ scope: String) -> Reading {
        let probe = app.descendants(matching: .any)["probe.duo.\(scope)"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "no Duo probe in \(scope)")
        let value = probe.value as? String ?? ""
        let attachment = XCTAttachment(string: value)
        attachment.name = "\(deviceSlug)__probe-\(scope).txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        return Reading(value, window: app.windows.firstMatch.frame)
    }

    private func bars(_ app: XCUIApplication, _ scope: String) -> String {
        let probe = app.descendants(matching: .any)["probe.bars.\(scope)"].firstMatch
        return probe.waitForExistence(timeout: 10) ? (probe.value as? String ?? "?") : "absent"
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

    private func selectLibrary(_ app: XCUIApplication) {
        let inBar = app.tabBars.buttons["Library"].firstMatch
        let target = inBar.exists ? inBar : app.buttons["Library"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 30), "no Library tab")
        target.tap()
    }

    private func capture(_ app: XCUIApplication, _ screen: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(deviceSlug)__duo-\(screen).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - The reader

    func testOuterDisplayReader() throws {
        try XCTSkipUnless(deviceSlug == "iphone-duo-outer", "not iPhone Duo's outer display")
        let app = launch()
        selectLibrary(app)
        let search = app.textFields["Title, author, narrator, series, tag"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "no library search field")
        search.tap()
        search.typeText("Peter and Wendy\n")
        let book = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                  "cell.book.", "Peter and Wendy"))
            .firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15), "the read-along book is not on the shelf")
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
        let back = app.buttons["Back to the book"].firstMatch
        if !back.waitForExistence(timeout: 3) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
            XCTAssertTrue(back.waitForExistence(timeout: 10), "the reader's tools never showed")
        }

        XCTAssertEqual(bars(app, "reader"), "trailing", "the system's bars are not down the side")
        let reading = reading(app, "reader")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(reading.trailing, 44, "no unsafe band down the side: \(reading.raw)")
        let railMinX = window.maxX - reading.trailing

        // Every tool in the rail, below the sensor bar, top to bottom in the
        // order the top bar has them left to right.
        let bookmark = app.buttons
            .matching(NSPredicate(format: "label IN %@", ["Bookmark this page", "Remove bookmark"]))
            .firstMatch
        var tools: [(String, XCUIElement)] = [("back", back)]
        let ask = app.buttons["reader.ask"].firstMatch
        if ask.exists { tools.append(("ask", ask)) }
        tools += [
            ("text options", app.buttons["Text options for this book"].firstMatch),
            ("bookmark", bookmark),
            ("more", app.descendants(matching: .any)["reader.more"].firstMatch),
        ]
        var previousBottom = reading.occludedTo
        for (name, element) in tools {
            guard element.exists else {
                XCTFail("the rail has no \(name) button")
                continue
            }
            let frame = element.frame
            XCTAssertGreaterThanOrEqual(frame.minX, railMinX - 1, "\(name) is not in the rail: \(frame)")
            XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 1, "\(name) runs off the edge: \(frame)")
            XCTAssertGreaterThanOrEqual(
                frame.minY, previousBottom - 1, "\(name) is under the sensor bar or out of order: \(frame)")
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\(name) is a smaller target than the bar's")
            previousBottom = frame.maxY
        }
        // Find and Marks are in the menu: the rail's capsule is four tools.
        XCTAssertFalse(app.buttons["reader.find"].exists, "Find stands in the rail as well as the menu")
        // The page stays clear of the rail, whether or not it shows.
        XCTAssertLessThanOrEqual(page.frame.maxX, railMinX + 1, "the page runs under the rail: \(page.frame)")
        capture(app, "reader")

        // Hiding the chrome takes the rail away and leaves the page alone;
        // showing it brings the rail back where it was, not at the island.
        let railBack = back.frame
        let pageFrame = page.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 5), "the middle tap did not take the rail away")
        XCTAssertEqual(page.frame, pageFrame, "hiding the rail moved the page")
        // With the rail away, its band turns the page as the page's own
        // right edge does.
        let before = page.value as? String
        app.coordinate(withNormalizedOffset: CGVector(
            dx: (railMinX + reading.trailing / 2) / window.width, dy: 0.5)).tap()
        let turned = NSPredicate { _, _ in (page.value as? String) != before }
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 5),
            .completed, "a tap in the empty band did not turn the page from \(before ?? "?")")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the rail did not come back")
        XCTAssertEqual(back.frame.minY, railBack.minY, accuracy: 1, "the rail came back somewhere else")
        XCTAssertEqual(page.frame, pageFrame, "showing the rail moved the page")

        // The menu, which holds Find, Marks and Contents, and the Contents
        // sheet, which has a Close where the bars run down the side.
        let more = app.descendants(matching: .any)["reader.more"].firstMatch
        more.tap()
        let contents = app.buttons["Contents"].firstMatch
        XCTAssertTrue(contents.waitForExistence(timeout: 10), "the rail's menu has no Contents")
        XCTAssertTrue(app.buttons["Find in book"].firstMatch.exists, "the rail's menu has no Find")
        capture(app, "readerMore")
        contents.tap()
        let close = app.buttons["sheet.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Contents has no Close with the bars down the side")
        capture(app, "contents")
        close.tap()
        XCTAssertTrue(
            close.waitForNonExistence(timeout: 10), "Close did not close Contents")
    }

    // MARK: - The shelf

    func testOuterDisplayLibrary() throws {
        try XCTSkipUnless(deviceSlug == "iphone-duo-outer", "not iPhone Duo's outer display")
        let app = launch()
        selectLibrary(app)
        XCTAssertTrue(app.textFields["Title, author, narrator, series, tag"].waitForExistence(timeout: 15))
        XCTAssertEqual(bars(app, "app"), "trailing", "the system's bars are not down the side")
        let window = app.windows.firstMatch.frame

        // Three covers across, as on a 402-point phone, in the space the bar
        // leaves.
        let cells = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "cell.book."))
            .allElementsBoundByIndex
            .map(\.frame)
            .filter { !$0.isEmpty }
        let top = cells.map(\.minY).min() ?? 0
        let firstRow = cells.filter { abs($0.minY - top) < 2 }
        XCTAssertEqual(firstRow.count, 3, "the shelf is not three covers across: \(firstRow)")

        // The tab bar down the side, past the middle of the screen.
        let tab = app.buttons["Library"].firstMatch
        XCTAssertTrue(tab.exists)
        XCTAssertGreaterThan(tab.frame.minX, window.midX, "the tab bar is not down the side: \(tab.frame)")
        capture(app, "library")
    }
}
