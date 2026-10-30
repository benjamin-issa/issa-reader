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
///
/// The row removed is "Pride and Prejudice", in the middle of the list, and
/// "Dracula" — the first row — is the one that has to be left alone. Removing
/// the first row proves little: a screen whose every gesture landed on the
/// first row would pass it, and the phone's Downloads screen once did exactly
/// that with its menu.
@MainActor
final class DownloadRemovalFlowTests: XCTestCase {
    /// The row removed, and the first row, which must survive it.
    private static let removed = "Pride and Prejudice"
    private static let first = "Dracula"

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

    /// At the largest text sizes the storage summary fills the first screen
    /// and the first row starts below the fold, where a swipe has nothing to
    /// land on. What is under test is the gesture, not where the row sits, so
    /// the screen is scrolled until the row can be touched.
    private func bringIntoView(_ row: XCUIElement, in app: XCUIApplication) {
        let screen = app.scrollViews["screen.downloads"]
        for _ in 0..<6 where !row.isHittable {
            screen.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.isHittable, "the row never scrolled into view")
    }

    /// Swipe, then the Delete the swipe reveals.
    ///
    /// The button is deliberately `accessibilityHidden` — VoiceOver gets the
    /// "Remove download" action instead — so it is tapped by position at the
    /// row's trailing edge, which is also the only way to prove the swipe
    /// actually revealed it. The edge is read before the swipe, because the
    /// card's own frame can slide with it.
    private func swipeToDelete(_ row: XCUIElement, in app: XCUIApplication) {
        let frame = row.frame
        row.swipeLeft()
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.maxX - 24, dy: frame.midY))
            .tap()
    }

    /// The whole point of the deferral: the row goes at once, and the reader is
    /// offered the way back. A toast whose button cannot be pressed is not an
    /// undo, and nothing but a tap can tell.
    func testUndoPutsTheRowBack() {
        let app = launch()
        openDownloads(app)

        let removed = row(Self.removed, in: app)
        let first = row(Self.first, in: app)
        XCTAssertTrue(removed.waitForExistence(timeout: 30), "no \(Self.removed) row to remove")
        bringIntoView(removed, in: app)
        swipeToDelete(removed, in: app)

        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the removal offered no undo")
        XCTAssertFalse(removed.exists, "the row should go at once, not when the window closes")
        XCTAssertTrue(first.exists, "the swipe removed the first row (\(Self.first)), not the one it was on")
        undo.tap()

        XCTAssertTrue(removed.waitForExistence(timeout: 5), "Undo did not put the row back")
        // Past the window the removal would have fired in. Nothing was deleted,
        // so this is the assertion that the timer was actually cancelled rather
        // than merely hidden.
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(removed.exists, "the cancelled removal fired anyway")
        XCTAssertTrue(first.exists)
        XCTAssertFalse(app.buttons["Undo"].firstMatch.exists, "the toast outstayed its window")
    }

    /// And the other direction: left alone, the window closes and the row stays
    /// gone. A test that only proved undo would pass on a removal that never
    /// removed anything.
    func testAnUnusedWindowCommitsTheRemoval() {
        let app = launch()
        openDownloads(app)

        let removed = row(Self.removed, in: app)
        let first = row(Self.first, in: app)
        XCTAssertTrue(removed.waitForExistence(timeout: 30), "no \(Self.removed) row to remove")
        bringIntoView(removed, in: app)
        swipeToDelete(removed, in: app)

        XCTAssertTrue(app.buttons["Undo"].firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 9)

        XCTAssertFalse(app.buttons["Undo"].firstMatch.exists, "the toast outstayed its window")
        XCTAssertFalse(removed.exists, "the removal did not happen when the window closed")
        XCTAssertTrue(first.exists, "the removal took the first row (\(Self.first)) with it")
    }
}
