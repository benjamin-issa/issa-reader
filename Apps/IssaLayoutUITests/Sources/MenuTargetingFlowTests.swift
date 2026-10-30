import XCTest

/// A book's hold menu, opened on each book in turn — the first, one in the
/// middle and the last — to prove the menu is the book pressed and nothing
/// else's.
///
/// These exist because every earlier test of a long press targeted "Dracula",
/// which is the first row of the Downloads screen and the first book of
/// everything else. On the phone that screen was one `List` row holding every
/// card, UIKit hung the menu from the row, and a press on any card opened the
/// *first* card's menu — so "Remove download" removed the first book. A test
/// that only ever pressed the first card could not tell that from working.
///
/// Three things are asserted for each press:
///
/// 1. **The menu is the book's.** Its items are exactly what `BookMenu`
///    produces for that book, in order, and the fixture's books differ in them
///    (Listen, Go to Series, the editions), so a menu that belongs to another
///    book shows up as a different list.
/// 2. **Nothing else is in it.** The comparison is of the whole list, so an
///    item the system adds — "Ask Siri", which is reported on iOS 27 in a menu
///    hung from a collection-view cell, though not on the simulator — fails it
///    as an unexpected item, and names it.
/// 3. **"View details" opens that book's page.** The one item every menu has,
///    and the one whose target is the book itself.
///
/// The expected lists are written out rather than computed: `BookMenu` is
/// tested in `Packages/IssaCore` (`BookMenuTests`), and a test that derived its
/// expectation from the code under test would agree with it however it broke.
/// They follow from the fixture (`FixtureLibrary`) and the rules in
/// `BookMenu.resolve`, noted beside each list.
@MainActor
final class MenuTargetingFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-IssaUITestFixture"] + extraArguments
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["card.continue"].waitForExistence(timeout: 120),
            "the fixture's catalogue never arrived")
        return app
    }

    // MARK: - The Downloads screen

    /// The Downloads rows the screen lists, top to bottom: each one's
    /// identifier, the fixture book it is, and its edition.
    ///
    /// The rows are one non-lazy stack, so every one of them is in the
    /// accessibility tree whether or not it is on screen; only pressing one
    /// needs it scrolled into view.
    private struct DownloadsRow {
        let identifier: String
        let title: String
        let edition: String
    }

    private func openDownloads(_ app: XCUIApplication) {
        let manage = app.buttons["Manage downloads"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 30), "no route to the Downloads screen")
        manage.tap()
        // By its rows, not by the screen's own identifier: what is under test
        // is what pressing a row does, whatever the screen is built from.
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "downloads.row.")).firstMatch
                .waitForExistence(timeout: 30),
            "the Downloads screen never listed a row")
    }

    private func downloadsRows(_ app: XCUIApplication) -> [DownloadsRow] {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "downloads.row."))
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 30), "the Downloads screen listed no rows")
        return query.allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { element in
                guard let title = FixtureMenus.titles.first(where: { element.label.hasPrefix("\($0), ") })
                else {
                    XCTFail("a Downloads row for no fixture book: \(element.label)")
                    return DownloadsRow(identifier: element.identifier, title: "", edition: "")
                }
                let edition = String(element.identifier.split(separator: "-").last ?? "")
                return DownloadsRow(identifier: element.identifier, title: title, edition: edition)
            }
    }

    /// The identifiers of the rows listed, read in a single snapshot of the
    /// screen, so it is quick enough to be taken inside an undo window.
    private func listedRowIdentifiers(in app: XCUIApplication) -> Set<String> {
        guard let root = try? app.snapshot() else {
            XCTFail("the screen could not be read")
            return []
        }
        var found = Set<String>()
        func walk(_ node: XCUIElementSnapshot) {
            if node.identifier.hasPrefix("downloads.row.") { found.insert(node.identifier) }
            node.children.forEach(walk)
        }
        walk(root)
        return found
    }

    private func downloadsRow(_ row: DownloadsRow, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[row.identifier].firstMatch
    }

    /// The first row, one in the middle, and the last.
    ///
    /// "Pride and Prejudice" is the middle: it is neither end of the fixture's
    /// order, and the read-along that `scripts/layout-sweep.sh` plants is what
    /// makes the last row a different book from the one before it.
    private func firstMiddleLast(
        of rows: [DownloadsRow],
    ) -> [(position: String, row: DownloadsRow)] {
        XCTAssertGreaterThanOrEqual(rows.count, 5, "the fixture plants at least five downloads")
        guard let middle = rows.first(where: { $0.title == "Pride and Prejudice" }) else {
            XCTFail("no Pride and Prejudice row to be the middle one")
            return []
        }
        let chosen = [("first", rows[0]), ("middle", middle), ("last", rows[rows.count - 1])]
        XCTAssertEqual(
            Set(chosen.map(\.1.identifier)).count, 3,
            "the first, middle and last rows are not three different rows")
        return chosen.map { (position: $0.0, row: $0.1) }
    }

    /// Long-press each of three rows: the menu is that row's book's, holds
    /// nothing else, and View details opens that book.
    func testEachDownloadsRowOpensItsOwnMenu() {
        let app = launch()
        openDownloads(app)

        for (position, target) in firstMiddleLast(of: downloadsRows(app)) {
            let row = downloadsRow(target, in: app)
            let books = "the \(position) row (\(target.title), \(target.edition))"

            bringIntoView(row, in: app)
            row.press(forDuration: 1.2)
            assertMenu(
                FixtureMenus.downloadsRow(title: target.title, edition: target.edition),
                in: app, for: books)

            app.buttons["View details"].firstMatch.tap()
            assertBookPage(showing: target.title, in: app, after: books)

            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(
                downloadsRow(target, in: app).waitForExistence(timeout: 15),
                "Back did not return to the Downloads screen")
        }
    }

    /// "Remove download" on a row that is not the first removes that row and
    /// no other — and Undo puts it back. Once on a middle row and once on the
    /// last.
    func testRemoveDownloadFromAMenuRemovesThePressedRow() {
        let app = launch()
        openDownloads(app)

        let rows = downloadsRows(app)
        let first = rows[0]
        for (position, target) in firstMiddleLast(of: rows).dropFirst() {
            let row = downloadsRow(target, in: app)
            let books = "the \(position) row (\(target.title), \(target.edition))"

            bringIntoView(row, in: app)
            row.press(forDuration: 1.2)
            let removals = app.buttons.matching(NSPredicate(format: "label == %@", "Remove download"))
            XCTAssertTrue(
                removals.firstMatch.waitForExistence(timeout: 10),
                "the menu on \(books) offered no removal")
            // The last of them, which is the row's own: a book whose other
            // edition is on the device too is offered that one's removal
            // first, and pressing it would remove a different row.
            removals.allElementsBoundByIndex.last?.tap()

            XCTAssertTrue(
                app.buttons["Undo"].firstMatch.waitForExistence(timeout: 5),
                "removing \(books) offered no undo")
            // One look at the list, and then the Undo: the window is six
            // seconds, and every query is a round trip to the app. The set
            // says all three things at once — the row is gone, the first row
            // is still there, and nothing else went.
            let remaining = listedRowIdentifiers(in: app)
            let expected = Set(rows.map(\.identifier)).subtracting([target.identifier])
            app.buttons["Undo"].firstMatch.tap()
            XCTAssertEqual(
                remaining, expected,
                "removing \(books) did not remove that row and only that row (the first is \(first.title))")

            XCTAssertTrue(row.waitForExistence(timeout: 5), "Undo did not put \(books) back")
            XCTAssertTrue(
                app.buttons["Undo"].firstMatch.waitForNonExistence(timeout: 5),
                "Undo did not take the toast down")
        }
    }

    // MARK: - The other surfaces

    /// The Reading tab's "Also reading" rows, which are a different component
    /// (`ResumeLink`) from the Downloads cards but the same kind of thing: a
    /// stack of rows, each with its own menu.
    func testEachAlsoReadingRowOpensItsOwnMenu() {
        let app = launch()
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Resume ", "% complete"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "no Also reading rows")
        let listed = rows.allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
            .map(\.label)
        // The fixture has three books with progress beside the Continue card's;
        // fewer is a different fixture, and the middle would be the first.
        XCTAssertGreaterThanOrEqual(listed.count, 2, "too few Also reading rows to tell one from another")

        var chosen = [("first", listed[0]), ("last", listed[listed.count - 1])]
        if listed.count >= 3 { chosen.insert(("middle", listed[listed.count / 2]), at: 1) }
        for (position, label) in chosen {
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", label)).firstMatch
            let books = "the \(position) Also reading row (\(label))"
            guard let title = FixtureMenus.titles.first(where: { label.hasPrefix("Resume \($0), ") }) else {
                return XCTFail("an Also reading row for no fixture book: \(label)")
            }

            bringIntoView(row, in: app)
            row.press(forDuration: 1.2)
            assertMenu(FixtureMenus.shelf(title: title), in: app, for: books)
            app.buttons["View details"].firstMatch.tap()
            assertBookPage(showing: title, in: app, after: books)

            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["screen.reading"].waitForExistence(timeout: 15),
                "Back did not return to the Reading tab")
        }
    }

    /// The library's flat grid.
    func testEachLibraryGridCellOpensItsOwnMenu() {
        let app = launch(["-issa.library.mode", "all"])
        let library = app.tabBars.buttons["Library"].exists
            ? app.tabBars.buttons["Library"] : app.buttons["Library"].firstMatch
        library.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.library"].waitForExistence(timeout: 15),
            "no Library tab")
        // Whichever shelf the grid opens on: the whole library, or the
        // Reading shelf a device that has used it before remembers, which
        // holds three of the six. Three is all that first, middle and last
        // need.
        pressFirstMiddleLastCell(in: app, backTo: "screen.library", atLeast: 3)
    }

    /// A tag's page, reached from a tag on a book's own: the same cells under
    /// a staged layout of its own (`BookListPage`).
    func testEachTagPageCellOpensItsOwnMenu() {
        let app = launch(["-issa.library.mode", "all"])
        let library = app.tabBars.buttons["Library"].exists
            ? app.tabBars.buttons["Library"] : app.buttons["Library"].firstMatch
        library.tap()
        let cell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "cell.book.")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "no book cell to open")
        cell.tap()
        let tag = app.descendants(matching: .any)["bookDetail.tag"].firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 15), "no linked tag on the book's page")
        tag.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.tag"].waitForExistence(timeout: 15),
            "the tag did not open its page")
        pressFirstMiddleLastCell(in: app, backTo: "screen.tag", atLeast: 6)
    }

    /// The book cells of the screen, in reading order, whether or not they are
    /// on it: a grid is lazy, so the screen is walked from the top down and
    /// each cell is noted as it first appears.
    private func bookCellsInReadingOrder(
        in app: XCUIApplication,
    ) -> [(identifier: String, label: String)] {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "cell.book."))
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 15), "no book cells")
        let scroller = mainScroller(in: app)
        var cells: [(identifier: String, label: String)] = []
        func note() -> Bool {
            var added = false
            for element in query.allElementsBoundByIndex
                .sorted(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) })
            where !cells.contains(where: { $0.identifier == element.identifier }) {
                cells.append((element.identifier, element.label))
                added = true
            }
            return added
        }
        _ = note()
        for _ in 0 ..< 8 {
            scroller.swipeUp(velocity: .slow)
            if !note() { break }
        }
        // And back to the top, where the first of them is: a lazy grid has no
        // cell above the viewport to scroll to, so every press after this
        // only ever scrolls down.
        let first = app.descendants(matching: .any)[cells[0].identifier].firstMatch
        for _ in 0 ..< 12 where !first.isHittable { scroller.swipeDown(velocity: .fast) }
        return cells
    }

    /// The screen's own vertical scroll view: the tallest, because a screen can
    /// also hold horizontal ones — the library's shelf chips are the first
    /// `scrollViews` match, and swiping on them scrolls nothing the cells are
    /// in.
    private func mainScroller(in app: XCUIApplication) -> XCUIElement {
        let candidates = app.scrollViews.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex
        return candidates.max { $0.frame.height < $1.frame.height } ?? app.scrollViews.firstMatch
    }

    /// The first, a middle and the last of the book cells on the screen, in
    /// reading order. Each is a cover, a title and a menu of its own.
    private func pressFirstMiddleLastCell(
        in app: XCUIApplication, backTo screen: String, atLeast count: Int,
    ) {
        let cells = bookCellsInReadingOrder(in: app)
        XCTAssertGreaterThanOrEqual(cells.count, count, "the fixture's books were not all laid out")

        for (position, cell) in [("first", cells[0]), ("middle", cells[cells.count / 2]), ("last", cells[cells.count - 1])] {
            guard let title = FixtureMenus.titles.first(where: { cell.label.contains($0) }) else {
                return XCTFail("a cell for no fixture book: \(cell.label)")
            }
            let element = app.descendants(matching: .any)[cell.identifier].firstMatch
            let books = "the \(position) cell (\(title))"

            bringIntoView(element, in: app)
            element.press(forDuration: 1.2)
            assertMenu(FixtureMenus.shelf(title: title), in: app, for: books)
            app.buttons["View details"].firstMatch.tap()
            assertBookPage(showing: title, in: app, after: books)

            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)[screen].waitForExistence(timeout: 15),
                "Back did not return to \(screen)")
        }
    }

    // MARK: - Driving a menu

    /// At the largest text sizes, or below a long list, an element can start
    /// below the fold or under the tab bar, where a long press has nothing to
    /// land on.
    private func bringIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "\(element) is not on the screen at all")
        let scroller = mainScroller(in: app)
        for _ in 0 ..< 10 where !element.isHittable {
            scroller.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable, "\(element) never scrolled into view")
    }

    /// The items of the menu that is open, top to bottom.
    ///
    /// A menu is a collection view whose cells each hold one button, labelled
    /// with the item's title; the button's identifier is its SF Symbol, which
    /// is how the menu is found — by the one item all of them have — without
    /// asking for a collection view and getting the screen's.
    private func openMenuItems(in app: XCUIApplication, for books: String) -> [String] {
        let details = app.buttons["View details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10), "the long press on \(books) opened no menu")
        let menu = app.collectionViews.containing(.button, identifier: "info.circle").firstMatch
        XCTAssertTrue(menu.exists, "the menu's items are not in a collection view any more")
        return menu.buttons.allElementsBoundByIndex.map(\.label)
    }

    /// The open menu is exactly `expected`, and names what differs.
    private func assertMenu(
        _ expected: [String], in app: XCUIApplication, for books: String,
        file: StaticString = #filePath, line: UInt = #line,
    ) {
        let actual = openMenuItems(in: app, for: books)
        let unexpected = actual.filter { !expected.contains($0) }
        let missing = expected.filter { !actual.contains($0) }
        XCTAssertEqual(
            actual, expected,
            """
            the menu on \(books) is not that book's menu.
            unexpected: \(unexpected.isEmpty ? "none" : unexpected.joined(separator: ", "))
            missing: \(missing.isEmpty ? "none" : missing.joined(separator: ", "))
            """,
            file: file, line: line)
    }

    private func assertBookPage(
        showing title: String, in app: XCUIApplication, after books: String,
        file: StaticString = #filePath, line: UInt = #line,
    ) {
        let page = app.descendants(matching: .any)["screen.bookDetail"]
        XCTAssertTrue(
            page.waitForExistence(timeout: 15), "View details on \(books) did not open a book page",
            file: file, line: line)
        XCTAssertTrue(
            page.staticTexts[title].waitForExistence(timeout: 10),
            "View details on \(books) opened a page that is not \(title)'s",
            file: file, line: line)
    }
}

/// What `BookMenu` offers each of the fixture's six books.
///
/// The books are `FixtureLibrary`'s, and the lists follow from it and from
/// `BookMenu.resolve`:
///
/// - **View details** is first on every surface here.
/// - **Resume** or **Read**: a book with progress resumes. Peter and Wendy,
///   Frankenstein, Pride and Prejudice and Dracula have it; the Time War and
///   the Ballad have none.
/// - **Listen**: the book has a read-along or an audiobook — Peter and Wendy,
///   Pride and Prejudice (read-along) and the Time War (audiobook).
/// - **Mark as** is absent: the stub server's status list is empty.
/// - **Rate** is always there.
/// - **Go to Series**: Dracula and the Ballad share a series, so the library
///   groups it.
/// - **More by** is absent: no author has a second book.
/// - **The editions**: one edition inline, several behind "Downloads". The
///   fixture puts the first-listed edition of each book on the device — the
///   read-along's EPUB and its ebook for Peter and Wendy, which the sweep
///   script plants — and the rest are offered for saving.
/// - **Remove download** is a Downloads row's own, last.
enum FixtureMenus {
    static let titles = [
        "Frankenstein; or, the Modern Prometheus",
        "The Ballad of Songbirds and Snakes",
        "This Is How You Lose the Time War",
        "Pride and Prejudice",
        "Peter and Wendy",
        "Dracula",
    ]

    /// The menu of a book on a screen with no row of its own: the library's
    /// grid, a tag's page, the Reading tab's rows.
    static func shelf(title: String) -> [String] {
        switch title {
        case "Dracula":
            ["View details", "Resume", "Rate", "Go to Series", "Remove download"]
        case "Frankenstein; or, the Modern Prometheus":
            ["View details", "Resume", "Rate", "Remove download"]
        case "The Ballad of Songbirds and Snakes":
            ["View details", "Read", "Rate", "Go to Series", "Remove download"]
        case "Pride and Prejudice":
            ["View details", "Resume", "Listen", "Rate", "Downloads"]
        case "This Is How You Lose the Time War":
            ["View details", "Read", "Listen", "Rate", "Downloads"]
        case "Peter and Wendy":
            ["View details", "Resume", "Listen", "Rate", "Downloads"]
        default:
            preconditionFailure("\(title) is not a fixture book")
        }
    }

    /// The menu of one Downloads row: the book's menu for its edition, with
    /// that edition left out of the editions and its removal last.
    static func downloadsRow(title: String, edition: String) -> [String] {
        switch (title, edition) {
        case ("Dracula", "ebook"):
            return ["View details", "Resume", "Rate", "Go to Series", "Remove download"]
        case ("Frankenstein; or, the Modern Prometheus", "ebook"):
            return ["View details", "Resume", "Rate", "Remove download"]
        case ("The Ballad of Songbirds and Snakes", "ebook"):
            return ["View details", "Read", "Rate", "Go to Series", "Remove download"]
        case ("Pride and Prejudice", "ebook"):
            return ["View details", "Resume", "Listen", "Rate", "Save for offline", "Remove download"]
        case ("This Is How You Lose the Time War", "ebook"):
            return ["View details", "Read", "Listen", "Rate", "Save for offline", "Remove download"]
        case ("Peter and Wendy", "ebook"), ("Peter and Wendy", "readaloud"):
            // The other edition is on the device too, so it is offered for
            // removal — inline, in the editions' place — before the row's own.
            return ["View details", "Resume", "Listen", "Rate", "Remove download", "Remove download"]
        default:
            preconditionFailure("\(title) (\(edition)) is not a fixture download")
        }
    }
}
