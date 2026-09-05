import XCTest

/// Lays out every screen worth checking at whatever width the destination is,
/// asserts the layout rules, and attaches a screenshot of each.
///
/// The screenshots are not decoration. Two of the four bugs this sweep exists
/// for are catchable by assertion; the other two — a control whose *inner*
/// padding drifted from the token — are not, because the text inside a
/// `TextField` is not a separate accessibility element and has no frame to
/// measure. The contact sheet's margin guides are the only coverage for that
/// class, so do not delete the screenshots for being slow.
// `@MainActor`, and every helper below it too. XCUITest's API surface is not
// Sendable-clean — `snapshot()` is main-actor isolated and returns a
// non-Sendable value — and this project builds with strict concurrency
// complete. Isolating the tests is the honest fix; relaxing the setting for
// this target would only hide it.
@MainActor
final class LayoutSweepTests: XCTestCase {
    /// Which device this run is, for the attachment names. Set by the sweep
    /// script with `TEST_RUNNER_ISSA_SWEEP_DEVICE=<slug>`.
    private var deviceSlug: String {
        ProcessInfo.processInfo.environment["ISSA_SWEEP_DEVICE"] ?? "device"
    }

    override func setUp() {
        super.setUp()
        // The default, but stated: a recorded failure must not abort the test,
        // so one method can visit five screens, record every violation, and
        // still attach every screenshot.
        continueAfterFailure = true
    }

    private func launch(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-IssaUITestFixture"] + extraArguments
        app.launch()
        return app
    }

    /// Selects a tab by its label, wherever the platform put the tabs.
    ///
    /// Not `app.tabBars.buttons[...]`: iPadOS 26 draws the tab set as a bar
    /// across the top rather than as a `.tabBar` element, so a query scoped to
    /// one found nothing and every iPad run stopped at the first tap. The label
    /// is the same on both, and `Tab(_:systemImage:value:)` gives no identifier
    /// to key on.
    private func selectTab(_ title: String, in app: XCUIApplication) {
        // `.firstMatch` throughout: "Library" is also the label of the Reading
        // tab's empty-state button, and an unqualified query that matches two
        // elements raises rather than picking one.
        let inBar = app.tabBars.buttons[title].firstMatch
        let target = inBar.exists ? inBar : app.buttons[title].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 30), "no \(title) tab")
        target.tap()
    }

    /// Waits until the catalogue has actually arrived.
    ///
    /// Every screen exists before it has anything on it, and the Reading tab's
    /// empty state is a centred block — so asserting the moment `screen.reading`
    /// appears measured "Nothing in progress" and reported a 140-point margin
    /// on a 402-point screen. The Continue card exists only once a book with
    /// progress is in hand, which is exactly the signal wanted.
    @discardableResult
    private func waitForLibrary(_ app: XCUIApplication) -> Bool {
        let loaded = app.descendants(matching: .any)["card.continue"]
            .waitForExistence(timeout: 120)
        XCTAssertTrue(loaded, "the fixture's catalogue never arrived")
        return loaded
    }

    private func capture(_ app: XCUIApplication, _ screen: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(deviceSlug)__\(screen).png"
        // Without this XCTest discards attachments for *passing* tests, which
        // is the majority case and would leave a contact sheet made only of
        // failures.
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Records what the app measured, so the contact sheet can draw guides
    /// without a second copy of the numbers.
    ///
    /// `make-contact-sheet.py` used to carry its own table of device point
    /// widths *and* its own `MARGIN_PT = 16` — a second and third copy of two
    /// values the app already knows, in a script whose whole job is to show
    /// whether the app's margin is where the token says. Both are read from
    /// here now, so a device added to the sweep needs no edit there and a
    /// margin that changes cannot leave the guides behind.
    private func recordReference(_ reference: LayoutReference) {
        let text = """
            margin=\(reference.screenMargin)
            width=\(reference.window.width)
            left=\(reference.safe.minX - reference.window.minX)
            right=\(reference.window.maxX - reference.safe.maxX)
            """
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(deviceSlug)__reference.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Signed out

    func testSignedOutScreen() throws {
        // No fixture flag: `AppModel` reads `issa.lastServer` through
        // UserDefaults, which consults the argument domain first, so an empty
        // one puts the app on the sign-in form with no stub server involved.
        let app = XCUIApplication()
        app.launchArguments = ["-IssaUITestFixture", "-issa.lastServer", ""]
        app.launch()

        XCTAssertTrue(app.otherElements["screen.signIn"].waitForExistence(timeout: 30))
        let reference = try LayoutReference.read(from: app)
        let root = try app.snapshot()

        assertHorizontallyContained(root, reference, screen: "signIn")
        // No margin assertion here. The sign-in screen is a centred form with
        // its own inset — `Metrics.spacing32`, not `screenMargin` — because it
        // is one column of prose rather than a shelf. Asserting the shelf's
        // margin against it would be asserting the wrong rule, and writing 32
        // into this file would put a second copy of a token where the whole
        // point is that there is one.
        assertScrollContentFits(root, reference)
        capture(app, "signIn")
    }

    // MARK: - Signed in

    func testSignedInScreens() throws {
        let app = launch()
        // The tab set, however this platform draws it.
        XCTAssertTrue(
            app.buttons["Reading"].waitForExistence(timeout: 60),
            "the app never showed its tabs")
        waitForLibrary(app)

        try check(app, screen: "reading", root: "screen.reading", content: "content.reading")

        selectTab("Library", in: app)
        try check(app, screen: "library", root: "screen.library", content: nil)

        // The Library tab opens on Browse — rails, not a grid — so the flat
        // shelf has to be asked for. `libraryMode` is persisted through
        // UserDefaults, which reads the argument domain first.
        app.terminate()
        let grid = launch(["-issa.library.mode", "all"])
        waitForLibrary(grid)
        selectTab("Library", in: grid)
        try check(grid, screen: "libraryGrid", root: "screen.library", content: nil)

        // The book screen is the highest-value one: it is where the 430-in-402
        // bug lived, and the fixture's books carry a long description, two
        // authors, tags and a rating so every row that can be over-wide is.
        let cell = grid.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "cell.book."))
            .firstMatch
        if cell.waitForExistence(timeout: 15) {
            cell.tap()
            try check(grid, screen: "bookDetail", root: "screen.bookDetail", content: "content.bookDetail")
        } else {
            XCTFail("no book cell to open")
        }

        selectTab("Settings", in: grid)
        // No margin assertion: Settings is a `List`, its row insets are UIKit's,
        // and asserting against Apple's private metrics is a test that breaks on
        // the next point release for no benefit. It still gets containment and
        // a screenshot.
        XCTAssertTrue(grid.descendants(matching: .any)["screen.settings"].waitForExistence(timeout: 15))
        let reference = try LayoutReference.read(from: grid)
        assertHorizontallyContained(try grid.snapshot(), reference, screen: "settings")
        capture(grid, "settings")
    }

    /// `content:` is accepted and ignored, deliberately — see below.
    private func check(
        _ app: XCUIApplication, screen: String, root identifier: String, content: String?
    ) throws {
        XCTAssertTrue(
            app.descendants(matching: .any)[identifier].waitForExistence(timeout: 30),
            "\(identifier) never appeared")
        let reference = try LayoutReference.read(from: app)
        let root = try app.snapshot()
        recordReference(reference)

        assertHorizontallyContained(root, reference, screen: screen)
        assertContentStartsAtTheMargin(root, reference, screen: screen)
        assertScrollContentFits(root, reference)
        assertRailsReachTheEdge(root, reference)
        // No container-frame check. An accessibility container's frame is the
        // union of its children, not a layout rect — a screen holding a rail,
        // or showing an empty state that fills the window, reports the safe
        // edges rather than its own margin. The mode of leading edges asks the
        // same question without needing the frame to mean something it does
        // not, and it is the form that would have caught all four of the bugs
        // this sweep exists for.
        capture(app, screen)
    }
}
