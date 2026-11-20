import XCTest

/// A link for one book arriving while another book's reader is open.
///
/// A "Currently reading" widget's second book, a Handoff, a Spotlight result
/// or a notification all arrive as `issareader://book/<uuid>`. The reader
/// that is up belongs to the page of the book being read, and the root used
/// to reset its stack and push the new book's page while that reader stayed
/// over everything: the other book's link did nothing, and Back from the
/// reader landed on the page of the book the link had named.
/// `MenuReaderDeepLinkFlowTests` covers the link to the same book.
///
/// Rows other than the first: the middle and the last book of the fixture
/// library are the targets, and the reader that is open is asserted by the
/// title it draws under its footer.
///
/// Needs the read-along fixture planted under the name of every book it
/// opens, in both editions, and the link watcher running; `scripts/layout-sweep.sh`
/// does both, and fails these tests rather than skipping them when the watcher
/// is missing.
@MainActor
final class ReaderLinkToAnotherBookFlowTests: XCTestCase {
    private static let open = (uuid: "11111111-1111-4111-8111-111111111111", title: "Peter and Wendy")
    private static let middle = (uuid: "33333333-3333-4333-8333-333333333333",
                                 title: "This Is How You Lose the Time War")
    private static let last = (uuid: "66666666-6666-4666-8666-666666666666",
                               title: "The Ballad of Songbirds and Snakes")

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        removeLinkFlag()
    }

    override func tearDown() {
        removeLinkFlag()
        super.tearDown()
    }

    func testLinkToTheMiddleBookFromTheLibraryTab() throws {
        try check(openFrom: "Library", link: Self.middle)
    }

    func testLinkToTheLastBookFromTheLibraryTab() throws {
        try check(openFrom: "Library", link: Self.last)
    }

    func testLinkToTheMiddleBookFromTheReadingTab() throws {
        try check(openFrom: "Reading", link: Self.middle)
    }

    func testLinkToTheLastBookFromTheReadingTab() throws {
        try check(openFrom: "Reading", link: Self.last)
    }

    /// The widget's own sequence: the first book opened by its link, then the
    /// second book's.
    func testSecondWidgetLinkWhileTheFirstWasOpenedByLink() throws {
        try check(openFrom: "link", link: Self.last)
    }

    func testMiddleWidgetLinkWhileTheFirstWasOpenedByLink() throws {
        try check(openFrom: "link", link: Self.middle)
    }

    /// The widget's real case: the phone is on the home screen when the link
    /// arrives, so the app is brought forward by it.
    func testLinkFromTheHomeScreenWhileTheReadingTabsReaderWasOpen() throws {
        try check(openFrom: "Reading", link: Self.last, fromHomeScreen: true)
    }

    func testLinkFromTheHomeScreenWhileTheLibraryTabsReaderWasOpen() throws {
        try check(openFrom: "Library", link: Self.middle, fromHomeScreen: true)
    }

    func testLinkFromTheHomeScreenWhileALinksReaderWasOpen() throws {
        try check(openFrom: "link", link: Self.last, fromHomeScreen: true)
    }

    /// The reader opened from a cover's menu sits on a page the screen's router
    /// pushed, not on one in the tab's path.
    func testLinkToTheLastBookWhileAMenusReaderWasOpen() throws {
        try check(openFrom: "menu", link: Self.last)
    }

    func testLinkToTheMiddleBookFromTheHomeScreenWhileAMenusReaderWasOpen() throws {
        try check(openFrom: "menu", link: Self.middle, fromHomeScreen: true)
    }

    /// A second link for the book whose page is the one on the stack, its
    /// reader closed: the path is `[book]` before and after, the page kept its
    /// identity, and the reader request was left armed with nothing to take
    /// it. Rows other than the first, as above.
    func testSecondLinkToTheMiddleBookWhoseReaderWasClosed() throws {
        try checkSecondLink(to: Self.middle)
    }

    func testSecondLinkToTheLastBookWhoseReaderWasClosed() throws {
        try checkSecondLink(to: Self.last)
    }

    /// A series page pushed from the book's own page covers it. A link for the
    /// same book replaces the stack's path with an equal one, so the series
    /// page used to stay on top, the request stayed armed with no page to take
    /// it, and Back later opened the reader nobody had asked for.
    func testLinkToTheLastBookFromItsSeriesPageOpensItsReader() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-IssaUITestFixture", "-issa.library.mode", "all"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["card.continue"].waitForExistence(timeout: 120),
                      "the fixture's catalogue never arrived")
        let target = Self.last

        let inBar = app.tabBars.buttons["Library"].firstMatch
        (inBar.exists ? inBar : app.buttons["Library"].firstMatch).tap()
        let search = app.textFields["Title, author, narrator, series, tag"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "no library search field")
        search.tap()
        search.typeText("\(target.title)\n")
        let cell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "cell.book.\(target.uuid)")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "\(target.title) is not on the shelf")
        cell.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.bookDetail"].waitForExistence(timeout: 15),
                      "the book's page did not open")

        let series = app.descendants(matching: .any)["bookDetail.series"].firstMatch
        var swipes = 0
        while !(series.exists && series.isHittable), swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(series.exists, "the page has no series link")
        series.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.series"].waitForExistence(timeout: 15),
                      "the series page did not open")

        // The widget's case, for the book whose page is under the series page.
        XCUIDevice.shared.press(.home)
        sleep(3)
        try deliverLink(toBook: target.uuid)

        let coach = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                                  "Reading gestures", "This book is narrated"))
            .firstMatch
        if coach.waitForExistence(timeout: 20) {
            coach.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(readerTitle(app, target.title).waitForExistence(timeout: 60),
                      "the link for the book under the series page opened nothing")

        // Closed, the page is the book's own and nothing opens again on Back.
        let back = app.buttons["Back to the book"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "no way back out of the reader")
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.bookDetail"].waitForExistence(timeout: 15))
        sleep(3)
        XCTAssertFalse(readerTitle(app, target.title).exists, "the reader opened again unasked")
    }

    // MARK: -

    private func checkSecondLink(to target: (uuid: String, title: String)) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-IssaUITestFixture", "-issa.library.mode", "all"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["card.continue"].waitForExistence(timeout: 120),
                      "the fixture's catalogue never arrived")

        try openReader(of: target.uuid, title: target.title, from: "link", in: app)
        XCTAssertTrue(readerTitle(app, target.title).waitForExistence(timeout: 60),
                      "the first link did not open \(target.title)'s reader")

        // Closed, onto the book's own page, which stays on the stack.
        let back = app.buttons["Back to the book"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "no way back out of the reader")
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.bookDetail"].waitForExistence(timeout: 15),
                      "closing the reader did not land on the book's page")
        XCTAssertFalse(readerTitle(app, target.title).exists, "the reader did not close")

        // The widget's case: from the home screen, for the same book again.
        XCUIDevice.shared.press(.home)
        sleep(3)
        try deliverLink(toBook: target.uuid)

        XCTAssertTrue(readerTitle(app, target.title).waitForExistence(timeout: 60),
                      "the second link for \(target.title), whose page was already up, opened nothing")
    }

    private func check(openFrom tab: String, link target: (uuid: String, title: String),
                       fromHomeScreen: Bool = false) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-IssaUITestFixture", "-issa.library.mode", "all"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["card.continue"].waitForExistence(timeout: 120),
                      "the fixture's catalogue never arrived")

        try openReader(of: Self.open.uuid, title: Self.open.title, from: tab, in: app)
        let reader = app.descendants(matching: .any)["screen.reader"]
        XCTAssertTrue(reader.waitForExistence(timeout: 60),
                      "the reader never opened: is the planted EPUB on disk under this book's name?")
        if !readerTitle(app, Self.open.title).waitForExistence(timeout: 20) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("the open reader is not \(Self.open.title)'s")
        }

        if fromHomeScreen {
            XCUIDevice.shared.press(.home)
            sleep(3)
        }
        try deliver(link: target.uuid, to: app)

        // The other book's reader, not the one that was open.
        XCTAssertTrue(readerTitle(app, target.title).waitForExistence(timeout: 60),
                      "the link for \(target.title) did not open its reader")
        XCTAssertFalse(readerTitle(app, Self.open.title).exists,
                       "\(Self.open.title)'s reader is still up")

        // Closing it lands on the linked book's page.
        let back = app.buttons["Back to the book"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "no way back out of the reader")
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.bookDetail"].waitForExistence(timeout: 15),
                      "closing the reader did not land on a book's page")
        XCTAssertTrue(
            app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS %@", target.title))
                .firstMatch.waitForExistence(timeout: 10),
            "the page under the reader is not \(target.title)'s")
    }

    /// Delivers a link to the running app, the way the widget does; see
    /// `LinkDelivery.swift`.
    private func deliver(link uuid: String, to app: XCUIApplication) throws {
        try deliverLink(toBook: uuid)
    }

    private func readerTitle(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        // The reader's own marker, which names its book on every device: the
        // caption under the page (`reader.bookTitle`) only fits above a home
        // indicator, so the iPad has none.
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "probe.reader.book", title))
            .firstMatch
    }

    private func openReader(of uuid: String, title: String, from tab: String, in app: XCUIApplication) throws {
        if tab == "link" {
            app.open(try XCTUnwrap(URL(string: "issareader://book/\(uuid)")))
            let coach = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                                      "Reading gestures", "This book is narrated"))
                .firstMatch
            if coach.waitForExistence(timeout: 20) {
                coach.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            return
        }
        // The menu route starts on the Library tab. Where the tabs are not in a
        // bar (the iPad's, the Duo's outer display), the button is found by the
        // tab's own name.
        let tabName = tab == "menu" ? "Library" : tab
        let inBar = app.tabBars.buttons[tabName].firstMatch
        (inBar.exists ? inBar : app.buttons[tabName].firstMatch).tap()
        if tab == "Library" || tab == "menu" {
            let search = app.textFields["Title, author, narrator, series, tag"]
            XCTAssertTrue(search.waitForExistence(timeout: 15), "no library search field")
            search.tap()
            search.typeText("\(title)\n")
        }
        let cell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "cell.book.\(uuid)")).firstMatch
        let card = app.descendants(matching: .any)["card.continue"].firstMatch
        if tab == "menu" {
            XCTAssertTrue(cell.waitForExistence(timeout: 15), "\(title) is not on the shelf")
            cell.press(forDuration: 1.2)
            let read = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Read", "Resume"))
                .firstMatch
            XCTAssertTrue(read.waitForExistence(timeout: 10), "the menu offered no Read")
            read.tap()
            let coach = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                                      "Reading gestures", "This book is narrated"))
                .firstMatch
            if coach.waitForExistence(timeout: 20) {
                coach.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            return
        }
        var viaCard = false
        if cell.waitForExistence(timeout: 15) {
            cell.tap()
        } else {
            viaCard = true
            XCTAssertTrue(card.exists, "\(title) is not on the \(tab) screen")
            card.tap()
        }
        // The Continue card asks for the reader itself, so there is no Read
        // button to press: a tap at its place would land on the reader.
        let reader = app.descendants(matching: .any)["screen.reader"].firstMatch
        if !viaCard || !reader.waitForExistence(timeout: 15) {
            let read = app.descendants(matching: .any)["action.read"].firstMatch
            XCTAssertTrue(read.waitForExistence(timeout: 15), "no Read action on the book screen")
            read.tap()
        }
        let coach = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                                  "Reading gestures", "This book is narrated"))
            .firstMatch
        if coach.waitForExistence(timeout: 20) {
            coach.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
}
