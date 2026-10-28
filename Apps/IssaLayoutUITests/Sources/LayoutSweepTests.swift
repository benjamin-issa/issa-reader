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
        // And not the books-from-Files list, which a reader who has used its
        // link lands on instead: an earlier test on this device may have.
        app.launchArguments = [
            "-IssaUITestFixture", "-issa.lastServer", "", "-issa.local.showsListSignedOut", "NO",
        ]
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

    // MARK: - Books from the reader's files

    /// The local list, populated and then empty.
    ///
    /// Signed out, with the book `scripts/layout-sweep.sh` plants in the app's
    /// `tmp/` added at launch (`-IssaUITestFixtureLocalImport`) — the picker is
    /// the system's and cannot be driven. Then the book is removed and, once
    /// the undo window has closed, the empty state is measured on the same
    /// screen. No margin assertion, as on sign-in: on iPad the list is a
    /// centred 640-point column, not a shelf at the screen margin.
    func testLocalBooksScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-IssaUITestFixture", "-issa.lastServer", "",
            "-IssaUITestFixtureLocalImport", "local-import.epub",
            // From sign-in, whatever an earlier run on this device left: the
            // argument domain is read before the stored choice.
            "-issa.local.showsListSignedOut", "NO",
        ]
        app.launch()
        XCTAssertTrue(app.otherElements["screen.signIn"].waitForExistence(timeout: 30))
        // The planted book is added as the app starts; give it the moment.
        let link = app.buttons["link.readFromFiles"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "no link to the books from Files")
        Thread.sleep(forTimeInterval: 3)
        link.tap()

        let list = app.descendants(matching: .any)["screen.localBooks"]
        XCTAssertTrue(list.waitForExistence(timeout: 15), "the link did not open the local list")
        let row = app.descendants(matching: .any)["localBook.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the planted book was not added")
        let reference = try LayoutReference.read(from: app)
        let root = try app.snapshot()
        recordReference(reference)
        assertHorizontallyContained(root, reference, screen: "localBooks")
        assertScrollContentFits(root, reference)
        capture(app, "localBooks")

        // Book info, from the row's menu.
        row.press(forDuration: 1.2)
        let infoItem = app.buttons["Book Info"].firstMatch
        XCTAssertTrue(infoItem.waitForExistence(timeout: 10), "the row's menu has no Book Info")
        infoItem.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.localBookInfo"].waitForExistence(timeout: 10))
        // Captured, not measured: on iPad a form sheet's dimming layer is an
        // image wider than the window, and it is the system's, not ours.
        capture(app, "localBookInfo")
        app.buttons["Done"].firstMatch.tap()

        // The reduced Settings a reader with no server has.
        let gear = app.buttons["button.localSettings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "no Settings button on the standalone list")
        gear.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.localSettings"].waitForExistence(timeout: 10))
        capture(app, "localSettings")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        // The card's frame slides with the swipe, so the revealed Remove is
        // tapped where its trailing edge was.
        let frame = row.frame
        row.swipeLeft(velocity: .slow)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.maxX - 24, dy: frame.midY))
            .tap()
        XCTAssertTrue(app.descendants(matching: .any)["localBooks.empty"].waitForExistence(timeout: 15))
        // Past the undo window, so the toast is not in the picture.
        Thread.sleep(forTimeInterval: 8)
        let empty = try app.snapshot()
        assertHorizontallyContained(empty, reference, screen: "localBooksEmpty")
        assertScrollContentFits(empty, reference)
        capture(app, "localBooksEmpty")
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

        // A rail that is not a series numbers nothing. Dracula and its sequel
        // are both recent arrivals in the fixture, and before the badge was
        // confined to the series rail a "2" sat on the sequel here.
        let recent = app.descendants(matching: .any)["rail.recently-added"]
        XCTAssertTrue(recent.waitForExistence(timeout: 15), "no Recently added rail on Browse")
        XCTAssertEqual(
            recent.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", " in Gothic Horror")).count,
            0, "a cut of the library numbered its covers as a series")

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

        // The series screen hangs off a book that is in one, and the shelf puts
        // the newest arrival first — which is not one of the fixture's Gothic
        // Horror pair. So this leg walks back and asks for Dracula by name.
        //
        // Back, not a cold relaunch. Relaunching cost eight to fifteen seconds
        // a device, and on a machine under memory pressure the second launch is
        // where the runner died — XCTest then restarted and re-ran only the
        // signed-out test, so the suite reported two tests and no failures
        // while quietly capturing neither this screen nor Settings. A pop needs
        // no new process and cannot be jetsammed.
        let shelf = grid
        shelf.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(shelf.descendants(matching: .any)["screen.library"]
            .waitForExistence(timeout: 15), "the book screen did not pop back to the shelf")
        // Found through the library's own search rather than by scrolling: the
        // grid is lazy, so a cell below the fold does not exist to be waited
        // for, and the fixture's series books are the oldest arrivals — last on
        // a shelf ordered by date, and on a 375-point screen further down than
        // a fixed number of swipes reliably reaches. A search puts the one cell
        // wanted at the top at every width.
        //
        // By label rather than by cell identifier, which would put a second
        // copy of a fixture UUID in this file: a cell is a button whose label
        // is everything the cover says, so the title is inside it either way.
        // The phone's search is a plain text field under the header, not a
        // `.searchable` bar, so it is found by the placeholder that names the
        // fields the index covers.
        let search = shelf.textFields["Title, author, narrator, series, tag"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "no library search field")
        search.tap()
        search.typeText("Dracula\n")
        let seriesBook = shelf.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Dracula"))
            .firstMatch
        XCTAssertTrue(seriesBook.waitForExistence(timeout: 15), "no series book to open")
        seriesBook.tap()

        // The rest of Dracula's series, on its page, numbered in it: the one
        // rail whose covers answer "which one of these".
        let seriesRail = shelf.descendants(matching: .any)["rail.the-gothic-horror"]
        XCTAssertTrue(seriesRail.waitForExistence(timeout: 15), "no series rail on Dracula's page")
        XCTAssertTrue(
            seriesRail.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Book 2 in Gothic Horror"))
                .firstMatch.exists,
            "the series rail's covers carry no number")

        // A tag on every fixture book links to its page, which lays out all
        // six of them.
        let tagLink = shelf.descendants(matching: .any)["bookDetail.tag"]
        XCTAssertTrue(tagLink.waitForExistence(timeout: 15), "no linked tag on Dracula's page")
        tagLink.tap()
        try check(shelf, screen: "tag", root: "screen.tag", content: "content.tag")
        XCTAssertEqual(bookCells(in: shelf).count, 6, "the tag page lost some of its books")
        shelf.navigationBars.buttons.firstMatch.tap()

        let seriesLink = shelf.descendants(matching: .any)["bookDetail.series"]
        XCTAssertTrue(seriesLink.waitForExistence(timeout: 15), "no series link in the hero")
        seriesLink.tap()
        try check(shelf, screen: "series", root: "screen.series", content: nil)

        selectTab("Settings", in: shelf)
        // No margin assertion: Settings is a `List`, its row insets are UIKit's,
        // and asserting against Apple's private metrics is a test that breaks on
        // the next point release for no benefit. It still gets containment and
        // a screenshot.
        XCTAssertTrue(shelf.descendants(matching: .any)["screen.settings"].waitForExistence(timeout: 15))
        let reference = try LayoutReference.read(from: shelf)
        assertHorizontallyContained(try shelf.snapshot(), reference, screen: "settings")
        capture(shelf, "settings")

        // Downloads & storage, pushed from it. Unlike Settings it is a
        // `ScrollView` and not a `List` on the phone — a `List` made every
        // card's long press open the first card's menu — so its margin is
        // ours to assert, as the Reading tab's is, and it has a screenshot at
        // every width: the storage card, the Wi-Fi rule, and the rows.
        let downloadsLink = shelf.buttons["Downloads & storage"].firstMatch
        for _ in 0..<4 where !(downloadsLink.exists && downloadsLink.isHittable) {
            shelf.collectionViews.firstMatch.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(downloadsLink.waitForExistence(timeout: 15), "no Downloads & storage row in Settings")
        downloadsLink.tap()
        try check(shelf, screen: "downloads", root: "screen.downloads", content: "content.downloads")
        // The rows are the fixture's planted downloads: a screen that drew the
        // storage card and no rows would still have a margin.
        XCTAssertTrue(
            shelf.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "downloads.row."))
                .firstMatch.waitForExistence(timeout: 15),
            "the Downloads screen listed none of the planted downloads")
        shelf.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(shelf.descendants(matching: .any)["screen.settings"].waitForExistence(timeout: 15),
                      "Back did not return to Settings")

        // Advanced, open, with the row to the books from Files, and the list
        // it pushes — the signed-in placement, inside the Settings tab.
        // Near the foot of the list, below the fold on a phone.
        let advanced = shelf.buttons["Advanced"].firstMatch
        for _ in 0..<6 where !(advanced.exists && advanced.isHittable) {
            shelf.collectionViews.firstMatch.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(advanced.waitForExistence(timeout: 15), "no Advanced disclosure")
        advanced.tap()
        for _ in 0..<4 where !shelf.descendants(matching: .any)["settings.localBooks"].firstMatch.isHittable {
            shelf.collectionViews.firstMatch.swipeUp(velocity: .slow)
        }
        let localRow = shelf.descendants(matching: .any)["settings.localBooks"].firstMatch
        XCTAssertTrue(localRow.waitForExistence(timeout: 15), "no row to the books from Files in Advanced")
        assertHorizontallyContained(try shelf.snapshot(), reference, screen: "settingsAdvanced")
        capture(shelf, "settingsAdvanced")
        localRow.tap()
        XCTAssertTrue(shelf.descendants(matching: .any)["screen.localBooks"].waitForExistence(timeout: 15),
                      "the Advanced row did not push the local list")
        let pushed = try shelf.snapshot()
        assertHorizontallyContained(pushed, reference, screen: "localBooksPushed")
        assertScrollContentFits(pushed, reference)
        capture(shelf, "localBooksPushed")
    }

    /// Every book cell's identifier on the screen, scrolling to find them: the
    /// grid is lazy, so a cell below the fold does not exist until it is near.
    private func bookCells(in app: XCUIApplication) -> Set<String> {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "cell.book."))
        var seen = Set(query.allElementsBoundByIndex.map(\.identifier))
        for _ in 0 ..< 8 {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            let now = Set(query.allElementsBoundByIndex.map(\.identifier))
            if now.isSubset(of: seen) { break }
            seen.formUnion(now)
        }
        return seen
    }

    // MARK: - The reader

    /// The reader, on the read-along book whose EPUB the sweep script plants.
    ///
    /// The plant had been dead setup since it was added: no leg here ever
    /// opened the reader, so its chrome — the progress readout, the bars, the
    /// narration controls — had no layout coverage at any width, and a
    /// generator failure went unnoticed. The script plants the file under the
    /// read-along's name and the ebook's, so whichever edition Read chooses
    /// for a book whose read-along the fixture does not call aligned, it is
    /// on disk; the stub server answers every file request with a 404, so a
    /// missing plant shows here as a reader that never draws a page.
    ///
    /// Reached the way a reader would: the shelf's search, the book screen,
    /// Read. The window reference is read on the book screen, before the
    /// reader covers the probe.
    ///
    /// Returns the window reference and the page, with the bars showing; nil
    /// after recording the failure when the reader never got that far.
    private func openReader(_ app: XCUIApplication) throws -> (reference: LayoutReference, page: XCUIElement)? {
        waitForLibrary(app)
        selectTab("Library", in: app)
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
            return nil
        }
        book.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.bookDetail"].waitForExistence(timeout: 15))
        let reference = try LayoutReference.read(from: app)
        recordReference(reference)

        let read = app.descendants(matching: .any)["action.read"].firstMatch
        guard read.waitForExistence(timeout: 15) else {
            XCTFail("no Read action on the book screen")
            return nil
        }
        read.tap()

        // The first-run guide is modal to accessibility, and takes the first
        // tap itself without turning a page.
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
        guard page.waitForExistence(timeout: 60) else {
            capture(app, "reader")
            XCTFail("the reader never drew a page: is the planted EPUB on disk under this book's name?")
            return nil
        }
        // The bars, so their layout is measured too. The middle of the page
        // toggles them; the edges would turn it.
        let back = app.buttons["Back to the book"].firstMatch
        if !back.waitForExistence(timeout: 3) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(back.waitForExistence(timeout: 10), "the reader's bars never showed")
        }
        return (reference, page)
    }

    func testReaderScreen() throws {
        let app = launch(["-issa.library.mode", "all"])
        guard let (reference, page) = try openReader(app) else { return }
        assertHorizontallyContained(try app.snapshot(), reference, screen: "reader")
        assertReaderTopBar(app, reference)
        assertBookTitleUnderFooter(app, reference)
        capture(app, "reader")

        // After the capture, which is the chrome as a reader first sees it.
        assertChromeLeavesThePageAlone(app, page)
        assertEllipsisMenuHoldsContents(app)
    }

    // MARK: - The reader's chrome

    /// The top bar: every tool in its own 44-point square, in the order the
    /// design gives, all of them in the bar rather than folded into the menu.
    ///
    /// At every width this sweep visits — 375 is the narrowest phone, and the
    /// full row is 316 points of it with Ask showing — so a regression that
    /// pushes Find into the ellipsis on a phone fails here before anyone sees
    /// it. The folded rows are for an iPad window too narrow to reach from
    /// here.
    private func assertReaderTopBar(_ app: XCUIApplication, _ reference: LayoutReference) {
        let ask = app.buttons["reader.ask"].firstMatch
        let bookmark = app.buttons
            .matching(NSPredicate(format: "label IN %@", ["Bookmark this page", "Remove bookmark"]))
            .firstMatch
        // Left to right. Ask is on a capable device's bar only, so it is
        // measured when it is there and not required.
        var row: [(name: String, element: XCUIElement)] = [
            ("back", app.buttons["Back to the book"].firstMatch),
        ]
        if ask.exists { row.append(("ask", ask)) }
        row += [
            ("find", app.buttons["reader.find"].firstMatch),
            ("text options", app.buttons["Text options for this book"].firstMatch),
            ("marks", app.buttons["reader.marks"].firstMatch),
            ("bookmark", bookmark),
            ("more", app.descendants(matching: .any)["reader.more"].firstMatch),
        ]

        var previousEdge = reference.window.minX
        for (name, element) in row {
            guard element.exists else {
                XCTFail("the top bar has no \(name) button")
                continue
            }
            let frame = element.frame
            XCTAssertGreaterThanOrEqual(
                frame.width, 43.5, "\(name) is \(frame.width) points wide, under a finger's 44")
            XCTAssertGreaterThanOrEqual(
                frame.height, 43.5, "\(name) is \(frame.height) points tall, under a finger's 44")
            XCTAssertGreaterThanOrEqual(
                frame.minX, previousEdge - 0.5, "\(name) overlaps what is to its left")
            XCTAssertLessThanOrEqual(
                frame.maxX, reference.window.maxX + 0.5, "\(name) runs off the right edge")
            previousEdge = frame.maxX
        }

        // The square is the button, not just the glyph in it: a tap near the
        // corner of the bookmark's square, well clear of its 15-point glyph,
        // has to toggle it.
        guard bookmark.exists else { return }
        let before = bookmark.label
        bookmark.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).tap()
        let flipped = app.buttons
            .matching(NSPredicate(format: "label IN %@ AND label != %@",
                                  ["Bookmark this page", "Remove bookmark"], before))
            .firstMatch
        XCTAssertTrue(flipped.waitForExistence(timeout: 5),
                      "a tap in the corner of the bookmark's square did nothing")
        // And back, so what follows sees the page as it found it.
        flipped.tap()
        XCTAssertTrue(app.buttons[before].waitForExistence(timeout: 5))
    }

    /// Whether this device has the band under the footer the title is drawn
    /// into: the sweep's home-button phone has none, and a notched phone has
    /// one. Nil for a run the script did not name, which then checks the title
    /// only if it is there.
    private var deviceHasTitleBand: Bool? {
        switch deviceSlug {
        case "device": nil
        case "iphone-se3": false
        default: true
        }
    }

    /// The book's title sits below the footer's controls, in the home
    /// indicator's band, clear of the indicator and of the controls.
    private func assertBookTitleUnderFooter(_ app: XCUIApplication, _ reference: LayoutReference) {
        let title = app.descendants(matching: .any)["reader.bookTitle"].firstMatch
        switch deviceHasTitleBand {
        case false?:
            XCTAssertFalse(title.waitForExistence(timeout: 2),
                           "a device with no band under the footer drew the title anyway")
            return
        case true?:
            XCTAssertTrue(title.waitForExistence(timeout: 10), "no book title under the footer")
        case nil:
            guard title.waitForExistence(timeout: 3) else { return }
        }
        let frame = title.frame
        XCTAssertTrue(title.label.contains("Peter and Wendy"), "the title says \(title.label)")
        // The band is the bottom 34 points on a notched phone, and the
        // indicator rests in its last 13.
        XCTAssertGreaterThanOrEqual(frame.minY, reference.window.maxY - 34 - 0.5,
                                    "the title is above the band, in the footer")
        XCTAssertLessThanOrEqual(frame.maxY, reference.window.maxY - 13 + 0.5,
                                 "the title reaches the home indicator")
        XCTAssertGreaterThanOrEqual(frame.minX, reference.window.minX)
        XCTAssertLessThanOrEqual(frame.maxX, reference.window.maxX)
        XCTAssertEqual(frame.midX, reference.window.midX, accuracy: 2, "the title is not centred")

        // Below every control in the footer, not beside or over any.
        let lowest = app.buttons.allElementsBoundByIndex
            .map(\.frame)
            .filter { $0.minY > reference.window.maxY * 0.8 && $0.maxY < frame.minY + 1 }
            .map(\.maxY)
            .max()
        XCTAssertNotNil(lowest, "no footer control found above the title")
        let overlapping = app.buttons.allElementsBoundByIndex
            .map(\.frame)
            .filter { $0.minY > reference.window.maxY * 0.8 && $0.intersects(frame) }
        XCTAssertTrue(overlapping.isEmpty, "the title overlaps a footer control: \(overlapping)")
    }

    /// Hiding the chrome takes the title with it and moves nothing: the page
    /// is exactly where it was, so no line re-paginated.
    private func assertChromeLeavesThePageAlone(_ app: XCUIApplication, _ page: XCUIElement) {
        let title = app.descendants(matching: .any)["reader.bookTitle"].firstMatch
        let back = app.buttons["Back to the book"].firstMatch
        let hadTitle = title.exists
        let before = page.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Not "does not exist": a bar faded to nothing and made untappable is
        // still in the accessibility tree.
        let gone = NSPredicate(format: "isHittable == false")
        let hidden = XCTNSPredicateExpectation(predicate: gone, object: back)
        XCTAssertEqual(XCTWaiter().wait(for: [hidden], timeout: 5), .completed,
                       "the middle tap did not hide the bars")
        if hadTitle {
            XCTAssertFalse(title.exists, "the title stayed on screen with the chrome hidden")
        }
        XCTAssertEqual(page.frame, before, "hiding the chrome moved the page")
        // Back, for whatever follows.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: back)
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: 10), .completed,
                       "the bars did not come back")
        if hadTitle {
            XCTAssertTrue(title.waitForExistence(timeout: 5), "the title did not come back")
        }
        XCTAssertEqual(page.frame, before, "showing the chrome moved the page")
    }

    /// Find and Marks are in the bar, so the menu holds Contents and neither
    /// of them. Marks is told apart by its label: the bar's is "Bookmarks and
    /// highlights", the menu's is "Marks".
    private func assertEllipsisMenuHoldsContents(_ app: XCUIApplication) {
        let more = app.descendants(matching: .any)["reader.more"].firstMatch
        guard more.exists else { return }
        more.tap()
        let contents = app.buttons["Contents"].firstMatch
        XCTAssertTrue(contents.waitForExistence(timeout: 5), "the ellipsis menu has no Contents")
        XCTAssertFalse(app.buttons["Marks"].exists, "Marks is in the menu as well as the bar")
        capture(app, "readerMore")
        // Out of the menu without choosing anything.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(app.buttons["Back to the book"].firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: - The highlight colours

    /// Each colour in the Highlight menu is drawn in its own colour.
    ///
    /// A menu paints a template symbol in the app's accent, so the five
    /// swatches were all tangerine and Plum, Rose, Slate and Moss could not be
    /// told apart by looking. Nothing but looking at the pixels shows that:
    /// the accessibility tree is the same whatever the icons are painted.
    ///
    /// The press-and-hold is how a reader selects, so it is how this does. If
    /// the page under it has no text the menu never appears, and that is
    /// reported as the selection having failed, not as a colour being wrong.
    func testHighlightMenuColours() throws {
        let app = launch(["-issa.library.mode", "all"])
        guard let (reference, _) = try openReader(app) else { return }

        // A third of the way down the page, in the text and clear of the tap
        // zones' edges.
        let spot = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        spot.press(forDuration: 0.9)
        let highlight = app.buttons["Highlight"].firstMatch
        guard highlight.waitForExistence(timeout: 10) else {
            capture(app, "readerHighlightMenu")
            return XCTFail("pressing and holding on the page selected nothing, so there is no Highlight menu to look at")
        }
        highlight.tap()
        let items = Dictionary(uniqueKeysWithValues: Self.highlightTints.map { tint in
            (tint.name, app.buttons[tint.name].firstMatch)
        })
        guard items["Plum"]?.waitForExistence(timeout: 10) == true else {
            capture(app, "readerHighlightMenu")
            return XCTFail("the Highlight menu never listed its colours")
        }
        capture(app, "readerHighlightMenu")

        let screenshot = XCUIScreen.main.screenshot().image
        guard let cgImage = screenshot.cgImage else { return XCTFail("no screenshot pixels") }
        // Points to pixels, from the screenshot itself rather than a guessed
        // device scale.
        let scale = CGFloat(cgImage.width) / reference.window.width

        var dominant: [String: [Int]] = [:]
        for tint in Self.highlightTints {
            guard let item = items[tint.name], item.exists else {
                XCTFail("no \(tint.name) item in the Highlight menu")
                continue
            }
            let frame = item.frame
            // The whole row: the swatch is at one end of it and the label at
            // the other, and which end is the platform's business. The label
            // is dark or white ink, which no tint is within tolerance of.
            let counts = Self.pixelCounts(
                in: cgImage,
                rect: CGRect(x: frame.minX * scale, y: frame.minY * scale,
                             width: frame.width * scale, height: frame.height * scale),
                near: Self.highlightTints.map(\.rgb), tolerance: 14)
            dominant[tint.name] = counts
            let own = counts[Self.highlightTints.firstIndex { $0.name == tint.name }!]
            XCTAssertGreaterThan(
                own, 60, "\(tint.name)'s swatch is not drawn in \(tint.name): \(counts) pixels near each tint")
            // And not in the accent instead, which is what a template does.
            if tint.name != "Tangerine" {
                let tangerine = counts[Self.highlightTints.firstIndex { $0.name == "Tangerine" }!]
                XCTAssertLessThan(
                    tangerine, 20, "\(tint.name)'s row is drawn in the accent: \(counts)")
            }
        }
        // Five different swatches: each row's strongest colour is its own.
        let strongest = Self.highlightTints.compactMap { tint -> Int? in
            dominant[tint.name]?.enumerated().max { $0.element < $1.element }?.offset
        }
        XCTAssertEqual(Set(strongest).count, Self.highlightTints.count,
                       "the five swatches are not five different colours: \(strongest)")
    }

    /// The five tints, as `ReaderPalette` states them.
    ///
    /// Copied rather than read from the app, because the app's `ReaderPalette`
    /// is what is under test and this is the independent statement of it: the
    /// hex values in the brief for the highlighter colours.
    private static let highlightTints: [(name: String, rgb: [Int])] = [
        ("Tangerine", [0xE2, 0x85, 0x3A]),
        ("Moss", [0x7C, 0x8A, 0x5A]),
        ("Slate", [0x2F, 0x3A, 0x3F]),
        ("Rose", [0xC4, 0x6A, 0x6A]),
        ("Plum", [0x8A, 0x6A, 0xA8]),
    ]

    /// How many pixels in `rect` lie within `tolerance` of each colour.
    private static func pixelCounts(
        in image: CGImage, rect: CGRect, near colours: [[Int]], tolerance: Int,
    ) -> [Int] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &data, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return colours.map { _ in 0 } }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var counts = colours.map { _ in 0 }
        let minX = max(0, Int(rect.minX)), maxX = min(width, Int(rect.maxX))
        let minY = max(0, Int(rect.minY)), maxY = min(height, Int(rect.maxY))
        guard minX < maxX, minY < maxY else { return counts }
        for y in minY ..< maxY {
            for x in minX ..< maxX {
                let offset = (y * width + x) * 4
                let r = Int(data[offset]), g = Int(data[offset + 1]), b = Int(data[offset + 2])
                for (index, colour) in colours.enumerated()
                where abs(r - colour[0]) <= tolerance
                    && abs(g - colour[1]) <= tolerance
                    && abs(b - colour[2]) <= tolerance {
                    counts[index] += 1
                }
            }
        }
        return counts
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
