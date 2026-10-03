import XCTest

/// A session that ends while the app is in use, and the two ways out of the
/// notice that says so: "Sign in again", and the books from Files.
///
/// The fixture server answers the catalogue once and then refuses the token
/// (`-IssaUITestFixtureRevokeAfterLoad`), which is a revoked device grant as
/// the app meets it: a 401 drops the token and the library gives way to the
/// "Your session has ended" notice.
///
/// "Sign in again" has to reach the browser. The notice and the form are one
/// sign-in screen; when they were two, the tap's own screen was torn down as
/// the phase moved on, the browser route it set went nowhere, and the reader
/// was left on "Welcome back" to tap again.
@MainActor
final class SignInAgainFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-IssaUITestFixture", "-IssaUITestFixtureRevokeAfterLoad",
            // From the library, whatever an earlier run left: the argument
            // domain is read before the stored choice.
            "-issa.local.showsListSignedOut", "NO",
        ] + extraArguments
        app.launch()
        return app
    }

    /// The catalogue, then any request after it — the library's own follow-up
    /// calls, or a pull to refresh if those have all been answered — which
    /// the server refuses, then the notice.
    private func expireTheSession(_ app: XCUIApplication) {
        let notice = app.buttons["button.signInAgain"]
        let deadline = Date().addingTimeInterval(150)
        while !notice.exists, Date() < deadline {
            if app.descendants(matching: .any)["screen.reading"].exists {
                // By coordinates: the screen can give way to the notice
                // between finding it and swiping it.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
            }
            _ = notice.waitForExistence(timeout: 8)
        }
        waitForNotice(app)
    }

    private func waitForNotice(_ app: XCUIApplication) {
        let shown = app.buttons["button.signInAgain"].waitForExistence(timeout: 30)
        if !shown { print("SCREEN-AT-FAILURE\n\(app.debugDescription)") }
        XCTAssertTrue(shown, "the revoked token never brought up the session-ended notice")
    }

    /// The browser route's own screen: the system's sign-in prompt is over
    /// it, but this button is the app's and only exists on that route.
    private func assertBrowserRoute(_ app: XCUIApplication, _ message: String) {
        XCTAssertTrue(app.buttons["Use a device code instead"].firstMatch.waitForExistence(timeout: 20), message)
        XCTAssertFalse(app.staticTexts["Welcome back."].exists, "the reader was left on the address form")
    }

    func testSignInAgainReachesTheBrowser() {
        let app = launch()
        expireTheSession(app)
        app.buttons["button.signInAgain"].firstMatch.tap()
        assertBrowserRoute(app, "Sign in again did not open the browser sign-in")
    }

    /// The notice's "Read a book from your files" opens the list there and
    /// then — it used to set a flag nothing on that screen read, which then
    /// took over the next sign-in instead. And the way back from the list
    /// is to the same notice, whose Sign in again still works.
    func testFilesLinkOnTheNoticeOpensTheListAndLeavesSignInAlone() {
        let app = launch(["-IssaUITestFixtureLocalImport", "local-import.epub"])
        expireTheSession(app)
        // The planted book is added as the app starts; with it on the device
        // the link opens the list rather than the picker.
        Thread.sleep(forTimeInterval: 3)
        app.buttons["link.readFromFiles"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.localBooks"].waitForExistence(timeout: 15),
                      "the link on the session-ended notice did nothing")

        let back = app.buttons["link.connectToServer"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the list offered no way back to the server")
        back.tap()
        waitForNotice(app)
        app.buttons["button.signInAgain"].firstMatch.tap()
        XCTAssertFalse(app.descendants(matching: .any)["screen.localBooks"].waitForExistence(timeout: 3),
                       "the list took over the sign-in the reader asked for")
        assertBrowserRoute(app, "Sign in again after the list did not open the browser sign-in")
    }
}
