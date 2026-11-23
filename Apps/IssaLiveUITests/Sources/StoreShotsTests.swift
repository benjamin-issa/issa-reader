import XCTest

/// The App Store's screenshots, taken from the real app signed in to a real
/// Storyteller, for `Tools/scripts/make-store-shots.py` to compose.
///
/// A store image has to be a real screen (App Review 2.3.3), and the layout
/// sweep's fixture library cannot supply one: its titles include modern books
/// that are not ours to show. So this signs the app into the local stack's
/// public-domain library, as `LiveServerTests` does, and walks to each screen
/// the store set shows: the library, a read-along with its sentence lit, the
/// player, the text options, a page at night, Downloads, and the books kept on
/// the device.
///
/// It does nothing on its own. It runs only when `E2E_STORE_SHOTS` is 1 as
/// well as `E2E_SERVER` being set, so an ordinary live check skips it and a
/// plain `xcodebuild test` of the scheme stays offline. Whoever drives it
/// passes the books as uuids, puts each book's position at the page wanted
/// before the run (and back afterwards), and approves the pairing code this
/// writes out, the way `scripts/live-check.sh` does.
///
/// Every page of book text it keeps is also written out as text, beside its
/// screenshot, because a store image must not carry a passage nobody read:
/// the page's accessibility label is its text.
@MainActor
final class StoreShotsTests: XCTestCase {
    /// One of the driver's settings, or nil; empty counts as unset. Read the
    /// way `LiveServerTests.setting` reads them, `nonisolated` for the same
    /// reason.
    private nonisolated func setting(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The folder on the Mac the PNGs, the page texts and the pairing code go
    /// to.
    private nonisolated var out: URL {
        URL(fileURLWithPath: setting("E2E_OUT") ?? NSTemporaryDirectory())
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            setting("E2E_STORE_SHOTS") == "1" && setting("E2E_SERVER") != nil,
            "takes the store screenshots only when asked: E2E_STORE_SHOTS=1 and a live E2E_SERVER")
        // A screen that cannot be reached must not cost the ones after it.
        continueAfterFailure = true
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    /// One method, for the reason `LiveServerTests` gives: each screen needs
    /// the sign-in, and a relaunch per screen would pair again each time.
    func testStoreScreens() throws {
        let server = try XCTUnwrap(setting("E2E_SERVER"))
        let app = XCUIApplication()
        // A book for "On this iPhone", handed over the way the document picker
        // would hand it (`LocalImportFixture`; the picker cannot be driven).
        // The driver plants it in the app's tmp once the app is installed,
        // and says so with `planted`, so the launch waits for that.
        if let local = setting("E2E_STORE_LOCAL_EPUB") {
            let planted = out.appendingPathComponent("planted")
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline, !FileManager.default.fileExists(atPath: planted.path) {
                Thread.sleep(forTimeInterval: 1)
            }
            app.launchArguments = ["-IssaUITestFixtureLocalImport", local]
        }
        app.launch()

        guard signIn(app, server: server) else {
            note("signIn FAIL never reached the library")
            XCTFail("never signed in")
            return
        }
        note("signIn PASS")

        if wants("library") { library(app) }
        if wants("readalong"), let book = setting("E2E_STORE_READALONG_BOOK") { readAlong(app, book: book) }
        if wants("night"), let book = setting("E2E_STORE_NIGHT_BOOK") { night(app, book: book) }
        if wants("downloads") { downloads(app) }
        if wants("local") { localBooks(app) }
    }

    /// Whether a screen is wanted this run. `E2E_STORE_SCREENS` names some of
    /// library, readalong, player, type, night, downloads and local, so one
    /// panel can be retaken without walking every screen again; unset, all.
    private func wants(_ screen: String) -> Bool {
        guard let list = setting("E2E_STORE_SCREENS") else { return true }
        return list.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == screen }
    }

    // MARK: - Screens

    /// The library, cut to one shelf so the screen shows only books chosen
    /// for it (`E2E_STORE_SHELF`, "To read" by default), and given time for
    /// the covers to arrive.
    private func library(_ app: XCUIApplication) {
        selectTab("Library", in: app)
        let shelf = setting("E2E_STORE_SHELF") ?? "To read"
        let chip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", shelf))
            .firstMatch
        guard chip.waitForExistence(timeout: 60) else {
            dump(app, "library-no-chip")
            note("library FAIL no \"\(shelf)\" chip")
            return
        }
        chip.tap()
        let cell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "cell.book."))
            .firstMatch
        _ = cell.waitForExistence(timeout: 30)
        Thread.sleep(forTimeInterval: 25)
        shot("library")
        note("library PASS \(shelf)")
    }

    /// A narrated book on a chosen page, with narration running: the sentence
    /// lit, then the player over it, then the text options, then Night.
    ///
    /// The page is found by its text (`E2E_STORE_READALONG_TEXT`), turning
    /// from wherever the driver's position opened it, because a position is
    /// only near a page and a store image must show the page that was read.
    private func readAlong(_ app: XCUIApplication, book: String) {
        guard openReader(app, book: book, timeout: 300) else {
            note("readAlong FAIL the reader did not open \(book)")
            return
        }
        if let text = setting("E2E_STORE_READALONG_TEXT"), !findPage(app, containing: text) {
            note("readAlong FAIL no page with \"\(text)\"")
            pageText(app, "readalong-unfound")
            return
        }
        if let text = setting("E2E_STORE_READALONG_TEXT"), let heading = setting("E2E_STORE_READALONG_HEADING") {
            openingPage(app, containing: text, heading: heading, avoiding: setting("E2E_STORE_READALONG_AVOID"))
        }
        pageText(app, "readalong-page")
        shot("readalong-still")

        let play = app.buttons["Play narration"].firstMatch
        if !(play.exists && play.isHittable) { toggleBars(app) }
        guard play.waitForExistence(timeout: 10) else {
            dump(app, "readalong-no-play")
            note("readAlong FAIL no Play narration button")
            return
        }
        play.tap()
        let pause = app.buttons["Pause narration"].firstMatch
        guard pause.waitForExistence(timeout: 60) else {
            dump(app, "readalong-not-playing")
            note("readAlong FAIL narration did not start")
            return
        }
        if let seconds = setting("E2E_STORE_READALONG_BURST").flatMap(TimeInterval.init) {
            // A screenshot every moment from Play on, each with the page it
            // showed, so the one where the wanted sentence is lit can be
            // chosen: the narration can open with words that are not on the
            // page, so no fixed wait lands on a given sentence.
            let started = Date()
            var frame = 0
            var log = ""
            while Date().timeIntervalSince(started) < seconds {
                frame += 1
                let name = String(format: "readalong-burst-%03d", frame)
                shot(name)
                let page = pageOnShow(app)
                log += String(format: "%@ %.1f s %@\n", name, Date().timeIntervalSince(started),
                              page.exists ? (page.value as? String ?? "") : "(no page)")
                Thread.sleep(forTimeInterval: 0.3)
            }
            try? Data(log.utf8).write(to: out.appendingPathComponent("readalong-burst.txt"))
            pageText(app, "readalong-burst-end")
        } else {
            // Three moments, so the set can use the one whose lit sentence
            // reads best; each with the page's text as it was then.
            for (index, wait) in [6.0, 5.0, 5.0].enumerated() {
                Thread.sleep(forTimeInterval: wait)
                pageText(app, "readalong-\(index + 1)")
                shot("readalong-\(index + 1)")
            }
        }
        note("readAlong PASS")
        guard wants("player") || wants("type") else {
            let stop = app.buttons["Pause narration"].firstMatch
            if !(stop.exists && stop.isHittable) { toggleBars(app) }
            if stop.waitForExistence(timeout: 5) { stop.tap() }
            Thread.sleep(forTimeInterval: 3)
            closeReader(app)
            return
        }

        // The player, from the reader's own button.
        let player = app.buttons["Open player"].firstMatch
        if wants("player"), !(player.exists && player.isHittable) { toggleBars(app) }
        if wants("player"), player.waitForExistence(timeout: 10) {
            player.tap()
            Thread.sleep(forTimeInterval: 4)
            shot("player")
            note("player PASS")
            // The sheet has no Done: it is dragged away, as a reader does.
            // On iPad it is a form sheet in the middle of the screen, so the
            // drag can miss it; a tap on the dimmed page beside it closes it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            Thread.sleep(forTimeInterval: 2)
            let options = app.buttons["Text options for this book"].firstMatch
            if UIDevice.current.userInterfaceIdiom == .pad, !(options.exists && options.isHittable) {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
                Thread.sleep(forTimeInterval: 2)
            }
        } else if wants("player") {
            dump(app, "player-no-button")
            note("player FAIL no Open player button")
        }

        if wants("type") { typeAndColour(app) }

        // Narration stopped before leaving, so nothing plays behind the
        // screens that follow; the mini player stays, as it would.
        let stop = app.buttons["Pause narration"].firstMatch
        if !(stop.exists && stop.isHittable) { toggleBars(app) }
        if stop.waitForExistence(timeout: 5) { stop.tap() }
        Thread.sleep(forTimeInterval: 3)
        closeReader(app)
    }

    /// Puts a chapter's first page on show with its heading at the top.
    ///
    /// The page break is the typesetter's, so the tail of whatever comes
    /// before the chapter can share its first page. Stepping the text size
    /// moves the break: from the size the reader starts at, up four steps
    /// and then down two, the first size at which the page holding `text`
    /// begins with `heading`, and lacks `avoiding` if that is given, is kept;
    /// failing that, the first at which it begins with `heading`; failing
    /// that, the size the reader started at.
    private func openingPage(_ app: XCUIApplication, containing text: String, heading: String, avoiding: String?) {
        func verdict() -> (top: Bool, clear: Bool) {
            guard findPage(app, containing: text) else { return (false, false) }
            let label = pageOnShow(app).label.trimmingCharacters(in: .whitespacesAndNewlines)
            return (label.hasPrefix(heading), avoiding.map { !label.contains($0) } ?? true)
        }
        var offset = 0
        var fallback: Int?
        for target in [0, 1, 2, 3, 4, -1, -2] {
            if target != offset {
                guard stepTextSize(app, by: target - offset) else { break }
                offset = target
            }
            let seen = verdict()
            note("opening size \(offset >= 0 ? "+" : "")\(offset): heading at top \(seen.top), clear \(seen.clear)")
            if seen.top, seen.clear { return }
            if seen.top, fallback == nil { fallback = offset }
        }
        let keep = fallback ?? 0
        if keep != offset, stepTextSize(app, by: keep - offset) { offset = keep }
        _ = findPage(app, containing: text)
        note("opening kept size \(offset >= 0 ? "+" : "")\(offset)")
    }

    /// Moves the text size by whole steps through the text options' stepper.
    private func stepTextSize(_ app: XCUIApplication, by steps: Int) -> Bool {
        let options = app.buttons["Text options for this book"].firstMatch
        if !(options.exists && options.isHittable) { toggleBars(app) }
        guard options.waitForExistence(timeout: 10) else { return false }
        options.tap()
        let done = app.buttons["Done"].firstMatch
        guard done.waitForExistence(timeout: 10) else { return false }
        let sized = app.steppers.matching(NSPredicate(format: "label BEGINSWITH %@", "Text size")).firstMatch
        let stepper = sized.waitForExistence(timeout: 5) ? sized : app.steppers.firstMatch
        let button = stepper.buttons[steps > 0 ? "Increment" : "Decrement"].firstMatch
        guard button.waitForExistence(timeout: 5) else {
            dump(app, "type-no-stepper")
            done.tap()
            return false
        }
        for _ in 0 ..< abs(steps) {
            button.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
        done.tap()
        Thread.sleep(forTimeInterval: 2.5)
        return true
    }

    /// The text options over the page: as it opens, in Sepia, with
    /// OpenDyslexic, and finally the page itself in Night.
    private func typeAndColour(_ app: XCUIApplication) {
        let options = app.buttons["Text options for this book"].firstMatch
        if !(options.exists && options.isHittable) { toggleBars(app) }
        guard options.waitForExistence(timeout: 10) else {
            dump(app, "type-no-button")
            note("type FAIL no Text options button")
            return
        }
        options.tap()
        guard app.buttons["Done"].firstMatch.waitForExistence(timeout: 10) else {
            dump(app, "type-no-sheet")
            note("type FAIL the text options did not open")
            return
        }
        Thread.sleep(forTimeInterval: 2)
        shot("type-sheet")

        tapSwatch(app, "Sepia")
        Thread.sleep(forTimeInterval: 2)
        pageText(app, "type-sepia")
        shot("type-sepia")

        // The typeface is a menu; its choices are buttons once it is open.
        let typeface = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Typeface")).firstMatch
        if typeface.waitForExistence(timeout: 5) {
            typeface.tap()
            let face = app.buttons["OpenDyslexic"].firstMatch
            if face.waitForExistence(timeout: 5) {
                face.tap()
                Thread.sleep(forTimeInterval: 3)
                pageText(app, "type-dyslexic")
                shot("type-dyslexic")
                note("type PASS OpenDyslexic")
            } else {
                dump(app, "type-no-face")
                note("type FAIL no OpenDyslexic in the menu")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            }
        } else {
            note("type FAIL no Typeface row")
        }

        tapSwatch(app, "Night")
        Thread.sleep(forTimeInterval: 2)
        shot("type-night")
        app.buttons["Done"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 3)
        pageText(app, "night-readalong")
        shot("night-readalong")
        note("night PASS read-along")
    }

    /// A second book, at night: whichever theme the reader left is the one
    /// every book opens in, and `typeAndColour` left Night.
    private func night(_ app: XCUIApplication, book: String) {
        guard openReader(app, book: book, timeout: 180) else {
            note("night FAIL the reader did not open \(book)")
            return
        }
        if let text = setting("E2E_STORE_NIGHT_TEXT"), !findPage(app, containing: text) {
            note("night FAIL no page with \"\(text)\"")
            pageText(app, "night-unfound")
            closeReader(app)
            return
        }
        Thread.sleep(forTimeInterval: 2)
        pageText(app, "night-page")
        shot("night-page")
        // With the bars, too: the set may want the reader's furniture.
        toggleBars(app)
        Thread.sleep(forTimeInterval: 2)
        shot("night-page-bars")
        note("night PASS second book")
        closeReader(app)
    }

    /// Settings › Downloads & storage, which says what the downloads are for.
    private func downloads(_ app: XCUIApplication) {
        guard openSettingsRow(app, matching: NSPredicate(format: "label BEGINSWITH %@", "Downloads & storage"))
        else {
            note("downloads FAIL no Downloads & storage row")
            return
        }
        Thread.sleep(forTimeInterval: 4)
        shot("downloads")
        note("downloads PASS")
        goBack(app)
    }

    /// Settings › Advanced › On this iPhone (or iPad): the books added from
    /// Files. The row is inside the Advanced disclosure, which is opened
    /// first, by coordinate, as `LiveServerTests.serverVersion` opens it.
    private func localBooks(_ app: XCUIApplication) {
        guard openSettingsRow(app, matching: NSPredicate(format: "label == %@", "Advanced")) else {
            note("local FAIL no Advanced row")
            return
        }
        Thread.sleep(forTimeInterval: 1.5)
        guard openSettingsRow(
            app, matching: NSPredicate(format: "identifier == %@", "settings.localBooks"), selectingTab: false)
        else {
            note("local FAIL no On this device row")
            return
        }
        let screen = app.descendants(matching: .any)["screen.localBooks"]
        _ = screen.waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 4)
        shot("local")
        note("local PASS")
        goBack(app)
    }

    // MARK: - Sign-in

    /// The sign-in `LiveServerTests.signIn` does: the address, a device code
    /// for the driver to approve, and a wait for a signed-in screen. Kept as
    /// its own copy so this class can change without touching the release
    /// checks.
    private func signIn(_ app: XCUIApplication, server: String) -> Bool {
        let signInScreen = app.descendants(matching: .any)["screen.signIn"]
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !signInScreen.exists, !isLanded(app) {
            Thread.sleep(forTimeInterval: 1)
        }
        if isLanded(app) { return true }
        guard signInScreen.exists else { return false }

        let field = app.textFields["field.serverAddress"].firstMatch
        guard field.waitForExistence(timeout: 30) else { return false }
        field.tap()
        if let typed = field.value as? String, !typed.isEmpty, typed != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count))
        }
        field.typeText(server)
        app.buttons["Use a device code"].firstMatch.tap()

        let code = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@", "^[A-Z0-9]( [A-Z0-9-]){6,}$"))
            .firstMatch
        var written = false
        let pairing = Date().addingTimeInterval(240)
        while Date() < pairing {
            if isLanded(app) { return true }
            if !written, code.exists {
                let text = code.label.replacingOccurrences(of: " ", with: "")
                written = (try? Data(text.utf8).write(to: out.appendingPathComponent("code.txt"), options: .atomic)) != nil
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    private func isLanded(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["screen.reading"].exists
            || app.descendants(matching: .any)["screen.library"].exists
    }

    // MARK: - The reader

    /// The page on show: its label is its text, its value "Page N of M in …".
    private func pageOnShow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Page "))
            .firstMatch
    }

    /// Opens a book by its link and clears the first-run guide, as
    /// `LiveServerTests.openReader` does.
    private func openReader(_ app: XCUIApplication, book: String, timeout: TimeInterval) -> Bool {
        guard let url = URL(string: "issareader://book/\(book)") else { return false }
        app.open(url)
        let page = pageOnShow(app)
        let guide = readingGuide(app)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !page.exists, !guide.exists {
            Thread.sleep(forTimeInterval: 1)
        }
        guard page.exists || guide.exists else {
            dump(app, "reader-never-ready")
            return false
        }
        // The narration tip can follow the zones' guide on a narrated book's
        // first open, so the guide is cleared until none is left.
        for _ in 0 ..< 3 {
            guard guide.waitForExistence(timeout: 5) else { break }
            guide.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = guide.waitForNonExistence(timeout: 10)
        }
        return page.waitForExistence(timeout: 20)
    }

    private func readingGuide(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                "Reading gestures", "This book is narrated"))
            .firstMatch
    }

    /// Turns until the page shows `text`: forward first, since the driver's
    /// position is at or just before the page, then back.
    private func findPage(_ app: XCUIApplication, containing text: String) -> Bool {
        let page = pageOnShow(app)
        if page.exists, page.label.contains(text) { return true }
        for (direction, turns) in [(CGFloat(1), 15), (CGFloat(-1), 30)] {
            for _ in 0 ..< turns {
                guard page.exists else { return false }
                let frame = page.frame
                let window = app.windows.firstMatch.frame
                let x = direction > 0 ? frame.maxX - 20 : frame.minX + 20
                app.coordinate(withNormalizedOffset: CGVector(
                    dx: (x - window.minX) / window.width,
                    dy: (frame.midY - window.minY) / window.height)).tap()
                Thread.sleep(forTimeInterval: 1.2)
                if page.exists, page.label.contains(text) { return true }
            }
        }
        return false
    }

    /// The middle of the page shows or hides the bars; the edges would turn it.
    private func toggleBars(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func tapSwatch(_ app: XCUIApplication, _ theme: String) {
        let swatch = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", theme))
            .firstMatch
        if swatch.waitForExistence(timeout: 5) { swatch.tap() } else { note("swatch FAIL no \(theme)") }
    }

    private func closeReader(_ app: XCUIApplication) {
        let back = app.buttons["Back to the book"].firstMatch
        if !(back.exists && back.isHittable) { toggleBars(app) }
        if back.waitForExistence(timeout: 5) { back.tap() }
        _ = app.descendants(matching: .any)["screen.reader"].waitForNonExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 2)
    }

    // MARK: - Settings

    /// Opens a Settings row, scrolling the lazy list until it is there.
    private func openSettingsRow(
        _ app: XCUIApplication, matching predicate: NSPredicate, selectingTab: Bool = true,
    ) -> Bool {
        // Not again for a row inside one just opened: a tap on the tab that
        // is already selected scrolls its list back to the top.
        if selectingTab { selectTab("Settings", in: app) }
        let list = app.descendants(matching: .any)["screen.settings"]
        guard list.waitForExistence(timeout: 20) else { return false }
        let row = app.descendants(matching: .any).matching(predicate).firstMatch
        for _ in 0 ..< 8 where !(row.exists && row.isHittable) { list.swipeUp() }
        guard row.exists else {
            dump(app, "settings-row-missing")
            return false
        }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
        Thread.sleep(forTimeInterval: 1)
    }

    private func selectTab(_ title: String, in app: XCUIApplication) {
        let inBar = app.tabBars.buttons[title].firstMatch
        let target = inBar.exists ? inBar : app.buttons[title].firstMatch
        if target.waitForExistence(timeout: 30) { target.tap() } else { note("tab FAIL no \(title)") }
        Thread.sleep(forTimeInterval: 1)
    }

    // MARK: - Output

    /// The whole screen, status bar included: the store image shows it.
    private func shot(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: out.appendingPathComponent("\(name).png"))
    }

    /// The text of the page on show, beside the screenshot of the same name.
    private func pageText(_ app: XCUIApplication, _ name: String) {
        let page = pageOnShow(app)
        let text = page.exists ? "\(page.value as? String ?? "")\n\n\(page.label)\n" : "(no page on show)\n"
        try? Data(text.utf8).write(to: out.appendingPathComponent("\(name).txt"), options: .atomic)
    }

    /// The accessibility tree and a screenshot, for a screen that was not
    /// where it was expected.
    private func dump(_ app: XCUIApplication, _ name: String) {
        shot(name)
        try? Data(app.debugDescription.utf8).write(to: out.appendingPathComponent("\(name).tree.txt"))
    }

    /// One line per screen in `notes.txt`, for the driver to print.
    private func note(_ line: String) {
        let url = out.appendingPathComponent("notes.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
