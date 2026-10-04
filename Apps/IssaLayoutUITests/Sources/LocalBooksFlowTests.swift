import XCTest

/// A book from the reader's files, end to end, as a reader with no server meets
/// it: the quiet link on the sign-in screen, the list, the reader with its
/// narration, back again, and a removal taken back.
///
/// The system's document picker cannot be driven, so the book arrives the way
/// the picker would hand it over — a URL into `LocalLibrary.importBooks` —
/// through `-IssaUITestFixtureLocalImport`, from the read-along fixture that
/// `scripts/layout-sweep.sh` plants in the app's `tmp/` as `local-import.epub`.
@MainActor
final class LocalBooksFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-IssaUITestFixture", "-issa.lastServer", "",
            "-IssaUITestFixtureLocalImport", "local-import.epub",
            // From sign-in, whatever an earlier run on this device left: the
            // argument domain is read before the stored choice.
            "-issa.local.showsListSignedOut", "NO",
        ]
        app.launch()
        return app
    }

    /// The row is one element carrying "Title, Author, …".
    private func row(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "The Patient Record of the Days"))
            .firstMatch
    }

    /// Swipe, then the Remove the swipe reveals, tapped where the card's
    /// trailing edge was before it slid — the card's own frame moves with it,
    /// and the button is hidden from VoiceOver, which has a Remove action
    /// instead.
    private func swipeToRemove(_ row: XCUIElement, in app: XCUIApplication) {
        let frame = row.frame
        row.swipeLeft(velocity: .slow)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.maxX - 24, dy: frame.midY))
            .tap()
    }

    func testReadAndRemoveABookFromFiles() {
        let app = launch()
        XCTAssertTrue(app.otherElements["screen.signIn"].waitForExistence(timeout: 30), "no sign-in screen")
        let link = app.buttons["link.readFromFiles"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "no quiet link to the books from Files")
        // The planted book is added as the app starts. With it on the device
        // the link opens the list; without it, the picker — which is this
        // test's failure, so it waits for the book first.
        Thread.sleep(forTimeInterval: 3)
        link.tap()

        XCTAssertTrue(app.descendants(matching: .any)["screen.localBooks"].waitForExistence(timeout: 15),
                      "the link did not open the local list")
        let book = row(in: app)
        XCTAssertTrue(book.waitForExistence(timeout: 15), "the planted book is not on the list")
        XCTAssertTrue(book.label.contains("Narrated"), "a read-along must say it is narrated: \(book.label)")

        // Into the reader, with its narration ready.
        book.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.reader"].waitForExistence(timeout: 30),
                      "the book did not open")
        let play = app.buttons["Play narration"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "a local read-along offered no narration")

        // The first-run guide, which a reader on a fresh device meets here:
        // it sits over the bars and takes the first tap itself, so the close
        // below would only have dismissed it. It shows once the page is ready
        // — the narration's button is the sign of that — and only until it
        // has been seen, which on a device another test has already read on
        // (the sweep runs `LayoutSweepTests` first) it has.
        let guide = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                "Reading gestures", "This book is narrated"))
            .firstMatch
        if guide.waitForExistence(timeout: 5) {
            guide.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(guide.waitForNonExistence(timeout: 10), "the reading guide did not go away")
        }

        // And back to the list. The reader has to be gone, not just the row
        // present: the list stays in the tree under the reader's cover, so
        // the row alone says nothing about whether the close worked.
        let back = app.buttons["Back to the book"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.reader"].waitForNonExistence(timeout: 15),
                      "the reader did not close")
        XCTAssertTrue(row(in: app).waitForExistence(timeout: 15), "closing the reader lost the list")

        // Swipe to remove; the row goes at once; Undo puts it back.
        // A beat for the reader's cover to finish leaving, then the swipe —
        // twice at most, since a swipe that lands while the list is still
        // settling only scrolls it.
        Thread.sleep(forTimeInterval: 1)
        let undo = app.buttons["Undo"].firstMatch
        for _ in 0..<2 where !undo.exists {
            swipeToRemove(row(in: app), in: app)
            _ = undo.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(undo.exists, "the removal offered no undo")
        XCTAssertFalse(row(in: app).exists, "the row should leave at once")
        undo.tap()
        XCTAssertTrue(row(in: app).waitForExistence(timeout: 5), "Undo did not put the book back")
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(row(in: app).exists, "the removal fired after it was taken back")
    }

    /// The hardware keyboard the design gives the list on iPad (3a): ⌘I opens
    /// Book info for the row the keyboard is on (the first, before any has
    /// been moved to), and ⌘Z takes a removal back through the window's undo
    /// manager while its toast is up. (⌘⌫, sent by XCUITest, never reached the
    /// app on the simulator; it is a hand check.)
    func testHardwareKeyboard() {
        let app = launch()
        let link = app.buttons["link.readFromFiles"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 30), "no quiet link to the books from Files")
        Thread.sleep(forTimeInterval: 3)
        link.tap()
        XCTAssertTrue(row(in: app).waitForExistence(timeout: 15), "the planted book is not on the list")

        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["screen.localBookInfo"].waitForExistence(timeout: 10),
                      "⌘I did not open Book info")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(row(in: app).waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)

        let undo = app.buttons["Undo"].firstMatch
        for _ in 0..<2 where !undo.exists {
            swipeToRemove(row(in: app), in: app)
            _ = undo.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(undo.exists, "the removal offered no undo")
        XCTAssertFalse(row(in: app).exists)

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(row(in: app).waitForExistence(timeout: 5), "⌘Z did not take the removal back")
    }
}
