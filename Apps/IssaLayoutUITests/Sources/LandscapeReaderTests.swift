import XCTest

/// The reader's page on an iPhone turned on its side: the text clears the
/// sensor housing and the rounded corners on both sides, at the default margin
/// and at the narrowest, and turning back to upright leaves the page exactly
/// where it began (1.7.1).
///
/// Measured against what the app says its window's safe area is (the reader's
/// `probe.duo.reader`, whose `safe=` field is `top,leading,bottom,trailing`),
/// not against numbers written here. Skips on an iPad and on iPhone Duo, where
/// the layout is meant to differ.
@MainActor
final class LandscapeReaderTests: XCTestCase {
    private var deviceSlug: String {
        ProcessInfo.processInfo.environment["ISSA_SWEEP_DEVICE"] ?? "device"
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    /// A failure must not leave the simulator sideways for the next test.
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(deviceSlug)__\(name).png"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func note(_ text: String, _ name: String) {
        let a = XCTAttachment(string: text)
        a.name = "\(deviceSlug)__\(name).txt"
        a.lifetime = .keepAlways
        add(a)
    }

    private func openReader(_ app: XCUIApplication) -> Bool {
        let inBar = app.tabBars.buttons["Library"].firstMatch
        let tab = inBar.exists ? inBar : app.buttons["Library"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 60), "no Library tab")
        tab.tap()
        let search = app.textFields["Title, author, narrator, series, tag"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "no library search field")
        search.tap()
        search.typeText("Peter and Wendy\n")
        let book = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                  "cell.book.", "Peter and Wendy"))
            .firstMatch
        guard book.waitForExistence(timeout: 15) else {
            XCTFail("the read-along book is not on the shelf")
            return false
        }
        book.tap()
        let read = app.descendants(matching: .any)["action.read"].firstMatch
        guard read.waitForExistence(timeout: 15) else {
            XCTFail("no Read action on the book screen")
            return false
        }
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
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Page ")).firstMatch
        guard page.waitForExistence(timeout: 60) else {
            XCTFail("the reader never drew a page")
            return false
        }
        return true
    }

    private func showBars(_ app: XCUIApplication) {
        let back = app.buttons["Back to the book"].firstMatch
        if !back.waitForExistence(timeout: 3) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(back.waitForExistence(timeout: 10), "the reader's bars never showed")
        }
    }

    private func setMargin(_ app: XCUIApplication, preset: String) {
        showBars(app)
        app.buttons["Text options for this book"].firstMatch.tap()
        let button = app.buttons["typography.margins.\(preset)"].firstMatch
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0 ..< 8 where !button.exists || !button.isHittable { list.swipeUp() }
        XCTAssertTrue(button.isHittable, "the \(preset) preset cannot be reached")
        button.tap()
        let done = app.buttons["Done"].firstMatch
        if !done.waitForExistence(timeout: 3) {
            for _ in 0 ..< 6 where !done.exists { list.swipeDown() }
        }
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the Aa sheet has no Done")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10), "the Aa sheet did not close")
    }

    /// The window's own safe-area insets, as the app reads them now.
    private func insets(_ app: XCUIApplication) -> (leading: CGFloat, trailing: CGFloat, raw: String) {
        let probe = app.descendants(matching: .any)["probe.duo.reader"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "no reader probe")
        let raw = probe.value as? String ?? ""
        let safe = raw.split(separator: ";")
            .first { $0.hasPrefix("safe=") }
            .map { $0.dropFirst(5).split(separator: ",").compactMap { Double($0) } } ?? []
        XCTAssertEqual(safe.count, 4, "unreadable safe area: \(raw)")
        guard safe.count == 4 else { return (0, 0, raw) }
        return (CGFloat(safe[1]), CGFloat(safe[3]), raw)
    }

    private func textFrame(_ app: XCUIApplication) -> CGRect {
        let probe = app.descendants(matching: .any)["probe.reader.textFrame"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "no text frame probe")
        return probe.frame
    }

    /// Waits for the reflow: the window has the new shape and the text frame
    /// has stopped moving for a moment.
    private func settle(_ app: XCUIApplication, landscape: Bool) {
        let window = app.windows.firstMatch
        let turned = NSPredicate { _, _ in
            let f = window.frame
            return landscape ? f.width > f.height : f.height > f.width
        }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15)
        var last = textFrame(app)
        var stable = 0
        let deadline = Date().addingTimeInterval(15)
        while stable < 3, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let now = textFrame(app)
            stable = now == last ? stable + 1 : 0
            last = now
        }
    }

    /// Every line of the page's text is inside the safe area on both sides.
    private func assertClear(_ app: XCUIApplication, _ label: String) -> CGRect {
        let window = app.windows.firstMatch.frame
        let side = insets(app)
        let text = textFrame(app)
        note("""
            \(label)
            window=\(window)
            safe=\(side.raw) -> leading=\(side.leading) trailing=\(side.trailing)
            text=\(text)
            """, "landscape-\(label)")
        XCTAssertGreaterThan(max(side.leading, side.trailing), 0,
                             "\(label): the phone reports no side safe area in landscape")
        XCTAssertGreaterThanOrEqual(text.minX, window.minX + side.leading - 0.5,
                                    "\(label): text starts at \(text.minX), inside the leading unsafe \(side.leading)")
        XCTAssertLessThanOrEqual(text.maxX, window.maxX - side.trailing + 0.5,
                                 "\(label): text ends at \(text.maxX), inside the trailing unsafe \(side.trailing)")
        // Not flush against the safe edge either: the margin is on top of it.
        XCTAssertGreaterThan(text.minX, window.minX + side.leading + 1, "\(label): no margin at the leading edge")
        XCTAssertLessThan(text.maxX, window.maxX - side.trailing - 1, "\(label): no margin at the trailing edge")
        // The footer's controls stay inside the safe area as well.
        for button in app.buttons.allElementsBoundByIndex {
            let f = button.frame
            guard button.exists, f.minY > window.height * 0.75, f.width > 0 else { continue }
            XCTAssertGreaterThanOrEqual(f.minX, window.minX + side.leading - 0.5, "\(label): footer control \(button.label) \(f)")
            XCTAssertLessThanOrEqual(f.maxX, window.maxX - side.trailing + 0.5, "\(label): footer control \(button.label) \(f)")
        }
        return text
    }

    func testPageClearsTheSensorHousingOnBothSidewaysPoses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-IssaUITestFixture", "-issa.library.mode", "all"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["card.continue"].waitForExistence(timeout: 120),
                      "the fixture's catalogue never arrived")
        guard UIDevice.current.userInterfaceIdiom == .phone, !deviceSlug.hasPrefix("iphone-duo") else {
            throw XCTSkip("the sideways clearance is a phone's, not an iPad's or the Duo's")
        }
        XCUIDevice.shared.orientation = .portrait
        guard openReader(app) else { return }
        showBars(app)
        let window0 = app.windows.firstMatch.frame
        let portraitInsets = insets(app)
        let portraitDefault = textFrame(app)
        note("window=\(window0) safe=\(portraitInsets.raw) text=\(portraitDefault)", "landscape-portrait-start")
        XCTAssertEqual(portraitInsets.leading, 0)
        XCTAssertEqual(portraitInsets.trailing, 0)
        attach(app, "landscape-0-portrait")

        var sideways: [CGRect] = []
        for (orientation, name) in [(UIDeviceOrientation.landscapeLeft, "landscapeLeft"),
                                    (.landscapeRight, "landscapeRight")] {
            XCUIDevice.shared.orientation = orientation
            settle(app, landscape: true)
            sideways.append(assertClear(app, "\(name)-default"))
            attach(app, "landscape-\(name)")
        }
        XCTAssertGreaterThan(sideways[0].minX, portraitDefault.minX,
                             "landscape's text starts no further in than portrait's")

        // The narrowest margin, in each pose.
        XCUIDevice.shared.orientation = .portrait
        settle(app, landscape: false)
        setMargin(app, preset: "edge")
        let portraitEdge = textFrame(app)
        XCTAssertEqual(portraitEdge.minX, 4, accuracy: 1.5, "Edge is not 4 points upright: \(portraitEdge)")
        for (orientation, name) in [(UIDeviceOrientation.landscapeLeft, "landscapeLeft"),
                                    (.landscapeRight, "landscapeRight")] {
            XCUIDevice.shared.orientation = orientation
            settle(app, landscape: true)
            _ = assertClear(app, "\(name)-edge")
            attach(app, "landscape-\(name)-edge")
        }

        // Back upright with the same margin: the page is where it was.
        XCUIDevice.shared.orientation = .portrait
        settle(app, landscape: false)
        XCTAssertEqual(textFrame(app), portraitEdge, "rotating back moved the Edge page")
        setMargin(app, preset: "standard")
        settle(app, landscape: false)
        let back = textFrame(app)
        XCTAssertEqual(back, portraitDefault, "after landscape the portrait page is not where it began")
        XCTAssertEqual(app.windows.firstMatch.frame, window0)
        attach(app, "landscape-9-portrait-again")
    }
}
