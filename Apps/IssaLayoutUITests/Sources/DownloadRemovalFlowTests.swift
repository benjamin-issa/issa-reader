import XCTest

/// The gestures on the downloads list, driven on a real device.
///
/// These exist because the unit tests for this behaviour passed twice while the
/// behaviour itself was broken. A removal is a swipe, a button in a transient
/// overlay and a cross on a progress bar — none of which a model-level test
/// touches. Anything that can only be verified by tapping belongs here.
///
/// Written against the fixture library, which plants one download per book, so
/// the rows below are the ones `FixtureLibrary.plantDownloads` writes.
@MainActor
final class DownloadRemovalFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-IssaUITestFixture"]
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["card.continue"].waitForExistence(timeout: 120),
            "the fixture's catalogue never arrived")
        return app
    }

    /// The rows combine their children, so a row is one element carrying
    /// "Title, Edition · Author, Size". Matched on the title alone, because the
    /// size is whatever the fixture happened to write.
    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), "))
            .firstMatch
    }

    private func openDownloads(_ app: XCUIApplication) {
        let manage = app.buttons["Manage downloads"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 30), "no route to the Downloads screen")
        manage.tap()
    }

    /// Swipe, then the Delete the swipe reveals.
    ///
    /// The button is deliberately `accessibilityHidden` — VoiceOver gets the
    /// "Remove download" action instead — so it is tapped by position at the
    /// row's trailing edge, which is also the only way to prove the swipe
    /// actually revealed it.
    private func swipeToDelete(_ row: XCUIElement) {
        row.swipeLeft()
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    /// The whole point of the deferral: the row goes at once, and the reader is
    /// offered the way back. A toast whose button cannot be pressed is not an
    /// undo, and nothing but a tap can tell.
    func testUndoPutsTheRowBack() {
        let app = launch()
        openDownloads(app)

        let dracula = row("Dracula", in: app)
        XCTAssertTrue(dracula.waitForExistence(timeout: 30), "no Dracula row to remove")
        swipeToDelete(dracula)

        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the removal offered no undo")
        XCTAssertFalse(dracula.exists, "the row should go at once, not when the window closes")
        undo.tap()

        XCTAssertTrue(dracula.waitForExistence(timeout: 5), "Undo did not put the row back")
        // Past the window the removal would have fired in. Nothing was deleted,
        // so this is the assertion that the timer was actually cancelled rather
        // than merely hidden.
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(dracula.exists, "the cancelled removal fired anyway")
        XCTAssertFalse(app.buttons["Undo"].firstMatch.exists, "the toast outstayed its window")
    }

    /// And the other direction: left alone, the window closes and the row stays
    /// gone. A test that only proved undo would pass on a removal that never
    /// removed anything.
    func testAnUnusedWindowCommitsTheRemoval() {
        let app = launch()
        openDownloads(app)

        let dracula = row("Dracula", in: app)
        XCTAssertTrue(dracula.waitForExistence(timeout: 30), "no Dracula row to remove")
        swipeToDelete(dracula)

        XCTAssertTrue(app.buttons["Undo"].firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 9)

        XCTAssertFalse(app.buttons["Undo"].firstMatch.exists, "the toast outstayed its window")
        XCTAssertFalse(dracula.exists, "the removal did not happen when the window closed")
    }
}
