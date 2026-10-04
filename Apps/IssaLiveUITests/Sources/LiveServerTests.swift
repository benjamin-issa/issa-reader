import XCTest

/// The release rule's live checks, driven on a simulator against a real
/// Storyteller rather than the layout sweep's fixture.
///
/// Every other suite in the repo talks to a stub, a captured response or a
/// fixture library, and each of 1.2.0's worst bugs got past all of them: the
/// cover redirect that signed readers out only happened on a real 3.x server,
/// and only once covers began to load. So this signs the real app into a real
/// server, the way a reader would, and looks at what it shows.
///
/// It does nothing on its own. `scripts/live-check.sh` sets it up — a server,
/// a book for each check, a fresh install — and passes the lot in as
/// `TEST_RUNNER_E2E_*`, which the test runner hands over without the prefix.
/// Without `E2E_SERVER` every test here skips, so a plain `xcodebuild test`
/// of the scheme stays offline. The script also approves the pairing code this
/// writes out and checks the server afterwards, which is where "reading a page
/// saved a position" is actually decided: nothing on screen proves a write
/// reached the server.
///
/// No launch argument, no fixture and no hook in the app: this is the build
/// that ships, with its real keychain and network, which is also why
/// `scripts/release.sh`'s fixture guard has nothing to say about it.
// `@MainActor` for the reason `LayoutSweepTests` gives: XCUITest's API is main
// actor isolated and this project builds with strict concurrency complete.
@MainActor
final class LiveServerTests: XCTestCase {
    /// One of the script's settings, or nil. Empty counts as unset: the script
    /// passes every variable on every run, blank where it has nothing to say.
    ///
    /// `nonisolated`, with `out` below, because `setUpWithError` is: XCTest
    /// calls it off the main actor whatever the class says.
    private nonisolated func setting(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Where the pairing code, screenshots and the per-check verdicts go — a
    /// path on the Mac. The runner is a simulator process, and a simulator
    /// process can write to the host's filesystem, which is what lets a shell
    /// loop outside approve a code that only exists on the simulated screen.
    private nonisolated var out: URL {
        URL(fileURLWithPath: setting("E2E_OUT") ?? NSTemporaryDirectory())
    }

    private var shots = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            setting("E2E_SERVER") != nil,
            "needs a live server: run scripts/live-check.sh, which sets TEST_RUNNER_E2E_SERVER")
        // One method visits every screen in turn and records each verdict, so
        // a failure early on must not cost the checks after it.
        continueAfterFailure = true
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    /// One method, not one per check. Each check needs the one before it — no
    /// library without a sign-in, no Settings row without a session — and
    /// XCTest runs methods alphabetically and relaunches between them, so
    /// splitting would buy a pairing per check and an order nobody chose.
    func testTheReleaseChecksAgainstALiveServer() throws {
        let server = try XCTUnwrap(setting("E2E_SERVER"))
        let app = XCUIApplication()
        app.launch()

        let landed = signIn(app, server: server)
        record("signIn", landed, landed ? signInMethod : "never reached the library")
        guard landed else { return }

        sessionSurvives(app)
        serverVersion(app)
        statusLabel(app)
        readAPage(app)
        if setting("E2E_AUDIO") == "1" { readAlong(app) }

        // Again at the end: a session that survived the covers can still be
        // lost to a reader's download or a position write.
        let end = signedIn(app)
        record("sessionAtEnd", end.passed, end.detail)
    }

    // MARK: - Checks

    /// How the run got in, for the summary: a real pairing, or a token the
    /// simulator's keychain kept across the reinstall.
    private var signInMethod = "already signed in"

    /// Types the server, asks for a device code, and hands the code to the
    /// script until the app lands on a signed-in screen.
    ///
    /// The simulator keychain survives an uninstall, so a device that has been
    /// signed in to this server before lands without a code; the script's
    /// `--fresh` resets the keychain when a real pairing is the point.
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
        // A reinstall starts with an empty field, but a run on a device that
        // still has a server remembered must not type after it.
        if let typed = field.value as? String, !typed.isEmpty, typed != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count))
        }
        field.typeText(server)
        capture(app, "typed")
        app.buttons["Use a device code"].firstMatch.tap()

        // Four minutes: the script's approver drives a real browser through
        // Storyteller's sign-in and approval pages, and the app then polls at
        // the server's interval.
        //
        // The code is found by shape, not by identifier. `DeviceCodeView`
        // speaks it one character at a time — "B S 5 3 - Y L N P" — so
        // VoiceOver spells it out, and that label is the only place the code
        // appears in the accessibility tree.
        let code = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@", "^[A-Z0-9]( [A-Z0-9-]){6,}$"))
            .firstMatch
        var written = false
        let pairing = Date().addingTimeInterval(240)
        while Date() < pairing {
            if isLanded(app) { return true }
            if !written, code.exists {
                let text = code.label.replacingOccurrences(of: " ", with: "")
                written = write(text, to: "code.txt")
                if written {
                    signInMethod = "paired with device code"
                    capture(app, "code")
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    /// The session outlives the covers.
    ///
    /// Covers are what signed 1.2.0 out: 3.x answers the cover route with a
    /// redirect. They load as the library appears, so thirty seconds on the
    /// library with no sign-in screen is the check, and the screenshot is what
    /// shows whether the covers themselves arrived.
    ///
    /// The library opens on Browse's rails unless a reader chose the grid, so
    /// either counts as the books having arrived.
    private func sessionSurvives(_ app: XCUIApplication) {
        selectTab("Library", in: app)
        let books = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "cell.book.", "rail."))
            .firstMatch
        let loaded = books.waitForExistence(timeout: 90)
        record("library", loaded, loaded ? "the library shows its books" : "no rail or book cell appeared")
        Thread.sleep(forTimeInterval: 30)
        capture(app, "library")
        let survived = signedIn(app)
        record("session", survived.passed, survived.passed
            ? "still signed in 30 s after the covers" : "while covers loaded: \(survived.detail)")
    }

    /// Settings › Advanced shows the version the script expects.
    ///
    /// Settings is a lazy list, so "Advanced" does not exist until it has been
    /// scrolled to, and the row is tapped by coordinate: the disclosure's
    /// label is not always the element that takes the tap.
    private func serverVersion(_ app: XCUIApplication) {
        selectTab("Settings", in: app)
        let list = app.descendants(matching: .any)["screen.settings"]
        guard list.waitForExistence(timeout: 20) else {
            record("serverVersion", false, "Settings never appeared")
            return
        }
        let advanced = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Advanced"))
            .firstMatch
        for _ in 0 ..< 8 where !(advanced.exists && advanced.isHittable) { list.swipeUp() }
        guard advanced.exists else {
            record("serverVersion", false, "no Advanced row in Settings")
            return
        }
        advanced.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let row = app.descendants(matching: .any)["settings.serverVersion"]
        for _ in 0 ..< 6 where !(row.exists && row.isHittable) { list.swipeUp() }
        capture(app, "advanced")
        guard row.exists else {
            record("serverVersion", false, "no Server version row under Advanced")
            return
        }
        // `LabeledContent` folds its value into the label — "Server version,
        // 3.0.0-beta.40" — and leaves `value` empty, so both are read.
        let shown = (row.value as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? row.label.replacingOccurrences(of: "Server version, ", with: "")
        guard let expected = setting("E2E_EXPECT_VERSION") else {
            record("serverVersion", true, "shows \"\(shown)\" (nothing expected)")
            return
        }
        record("serverVersion", shown == expected, "shows \"\(shown)\", expected \"\(expected)\"")
    }

    /// A book's status pill shows the server's label for its status.
    ///
    /// Reached through a library search rather than a deep link: the app
    /// treats `issareader://book/<uuid>` as "carry on reading" and opens the
    /// reader, and opening a book is exactly what could change its status.
    private func statusLabel(_ app: XCUIApplication) {
        // A check that did not run is a FAIL, never a PASS: this line used to
        // read "PASS skipped", and the summary is the release record. The
        // script refuses to start without the book; this is the second lock.
        guard let expected = setting("E2E_STATUS_LABEL"), let title = setting("E2E_STATUS_TITLE") else {
            record("statusLabel", false, "not run: no status book given")
            return
        }
        selectTab("Library", in: app)
        let field = app.textFields["Title, author, narrator, series, tag"].firstMatch
        guard field.waitForExistence(timeout: 20) else {
            record("statusLabel", false, "no library search field")
            return
        }
        field.tap()
        if let typed = field.value as? String, !typed.isEmpty, typed != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count))
        }
        field.typeText(title + "\n")

        // By uuid where the script knows it: two editions can share a title.
        let cell = setting("E2E_STATUS_BOOK").map { app.descendants(matching: .any)["cell.book.\($0)"] }
            ?? app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "cell.book.")).firstMatch
        guard cell.waitForExistence(timeout: 20) else {
            record("statusLabel", false, "\"\(title)\" is not in the library")
            return
        }
        cell.tap()
        let pill = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["Change reading status", "Set reading status"]))
            .firstMatch
        guard pill.waitForExistence(timeout: 20) else {
            record("statusLabel", false, "no status pill on \"\(title)\"")
            return
        }
        capture(app, "status")
        let shown = pill.value as? String ?? ""
        record("statusLabel", shown == expected, "\"\(title)\" shows \"\(shown)\", expected \"\(expected)\"")
    }

    /// Opens a book, turns three pages, and waits for the position to leave.
    ///
    /// The turn is judged here, by the page itself: its accessibility label is
    /// the page's text and its value "Page N of M in <chapter>"
    /// (`PageAccessibility`), read before the taps and after. Recording PASS
    /// on the taps alone said "turned three pages" for a reader whose
    /// right-edge tap did nothing. Whether the position reached the server —
    /// and, on 3.x, whether it filed a book that had no status — is the
    /// script's to check over the API afterwards: two seconds of debounce and
    /// a queue drain happen after the last tap, and nothing on screen says
    /// they finished. The script puts the book at its start first, so three
    /// pages forward always has somewhere to go.
    private func readAPage(_ app: XCUIApplication) {
        guard let book = setting("E2E_READ_BOOK") else {
            record("readerOpened", false, "not run: no book to read given")
            return
        }
        if let failure = openReader(app, book: book) {
            record("readerOpened", false, "\(book): \(failure)")
            return
        }
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Page "))
            .firstMatch
        guard page.waitForExistence(timeout: 30) else {
            capture(app, "reader")
            record("readerOpened", false, "the reader opened \(book) but drew no page")
            return
        }
        let before = pageReading(page)
        capture(app, "reader")
        for _ in 0 ..< 3 {
            // The right edge turns forward; the middle would toggle the bars.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        let after = page.exists ? pageReading(page) : nil
        Thread.sleep(forTimeInterval: 15)
        capture(app, "reader-turned")
        guard let after else {
            record("readerOpened", false, "the page went away while turning")
            return
        }
        let turned = after != before
        record("readerOpened", turned, turned
            ? "turned from \"\(before.value)\" to \"\(after.value)\""
            : "three taps on the right edge left the page at \"\(before.value)\"")

        // And out again, as a reader leaves a book. A reader still up after
        // its close is reported here, by name, rather than as whatever the
        // next check fails to find under it.
        let closed = closeReader(app)
        record("readerClosed", closed == nil, closed ?? "Back to the book closed the reader")
    }

    /// The page's text and its place, together: either changing is a turn.
    /// The place alone can repeat across chapters ("Page 1 of 1"), and the
    /// text alone can be empty on a picture page.
    private func pageReading(_ page: XCUIElement) -> (label: String, value: String) {
        (page.label, page.value as? String ?? "")
    }

    /// Plays a read-along past the end of its first audio file.
    ///
    /// The Gap Book's first file ends in an after-hole, audio that runs on past
    /// the file's last sentence: the crossing 1.3.0 had to fix, and the one a
    /// coordinator that misreads a file's end would stop or loop at. It plays
    /// through the Mac's speakers, which is why the script asks for `--audio`
    /// explicitly.
    ///
    /// Only stopping is judged here. A player looping at the file's end, or
    /// stuck on it, still shows Pause narration, so whether it got past is
    /// the script's to decide from where the position ended up. The script
    /// puts the book back at the top of its first chapter before the run, and
    /// 75 s is measured from there: the Gap Book's first file is under a
    /// minute, so by then narration is into the second, where the pause at
    /// the end is saved.
    private func readAlong(_ app: XCUIApplication) {
        guard let book = setting("E2E_READALONG_BOOK") else {
            record("readAlong", false, "--audio given but no read-along book")
            return
        }
        // The narrated book is a larger download than a plain EPUB.
        if let failure = openReader(app, book: book, timeout: 240) {
            record("readAlong", false, "\(book): \(failure)")
            return
        }
        let play = app.buttons["Play narration"].firstMatch
        for _ in 0 ..< 3 where !(play.exists && play.isHittable) {
            // The bars may be hidden; the middle of the page shows them.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = play.waitForExistence(timeout: 5)
        }
        guard play.exists else {
            record("readAlong", false, "no Play narration button")
            return
        }
        play.tap()
        let pause = app.buttons["Pause narration"].firstMatch
        guard pause.waitForExistence(timeout: 30) else {
            record("readAlong", false, "narration did not start")
            return
        }
        let seconds = setting("E2E_READALONG_SECONDS").flatMap(TimeInterval.init) ?? 75
        Thread.sleep(forTimeInterval: seconds)
        capture(app, "readalong")
        let playing = pause.exists
        record("readAlong", playing, playing
            ? "still playing after \(Int(seconds)) s"
            : "stopped before \(Int(seconds)) s")
        if pause.exists { pause.tap() }
        // The pause is a position change like any other, saved after the
        // same two-second debounce, and the script reads what it leaves: the
        // test ending first would take that write with it.
        Thread.sleep(forTimeInterval: 10)
    }

    // MARK: - Helpers

    /// Signed in, on either tab a session can open on. After a sign-in the app
    /// shows Reading, not the Library.
    private func isLanded(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["screen.reading"].exists
            || app.descendants(matching: .any)["screen.library"].exists
    }

    private func signedOut(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["screen.signIn"].exists
            || app.staticTexts["Your session has ended."].exists
    }

    /// Signed in, on the evidence of something a signed-in app shows, not
    /// only the absence of the sign-in screen. A crashed or quit app shows no
    /// sign-in screen either, so "not signed out" passed both session checks
    /// over an app that was no longer running.
    ///
    /// The witness is the app in the foreground and either a signed-in tab
    /// or the reader: its Back button, or its page while the bars are hidden.
    private func signedIn(_ app: XCUIApplication) -> (passed: Bool, detail: String) {
        guard app.state == .runningForeground else {
            return (false, "the app is not running in the foreground (state \(app.state.rawValue))")
        }
        if signedOut(app) { return (false, "signed out") }
        let any = app.descendants(matching: .any)
        // The book page too: closing the reader of a book opened by its link
        // leaves the reader on that book's page, pushed over the tab's root.
        let onATab = isLanded(app) || any["screen.settings"].exists || any["screen.bookDetail"].exists
        let inTheReader = app.buttons["Back to the book"].exists
            || any.matching(NSPredicate(format: "value BEGINSWITH %@", "Page ")).firstMatch.exists
        guard onATab || inTheReader else {
            return (false, "no signed-in screen and no reader on show")
        }
        return (true, "still signed in")
    }

    /// Opens a book by the same link a widget uses, and dismisses the
    /// first-run guide when it comes up.
    ///
    /// `open` relaunches the app with the URL. On a fresh install the reader
    /// opens under its first-run guide (`ReaderCoachOverlay`) — the zones on
    /// the first book, the narration tip on the first narrated one — which a
    /// live check meets as a first-time reader does: it is not pre-dismissed
    /// through the app's defaults. The guide comes up once the page is ready,
    /// which can be after the reader's Back button is already there; it takes
    /// the next tap itself, and while it shows it is modal to accessibility,
    /// so neither the page nor the bars are in the tree. So the open waits
    /// for the page or the guide, not for the Back button.
    ///
    /// - Returns: nil once the reader is up and clear, else what went wrong.
    private func openReader(_ app: XCUIApplication, book: String, timeout: TimeInterval = 120) -> String? {
        guard let url = URL(string: "issareader://book/\(book)") else { return "no link for the book" }
        app.open(url)
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Page "))
            .firstMatch
        let guide = readingGuide(app)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !page.exists, !guide.exists {
            Thread.sleep(forTimeInterval: 1)
        }
        guard page.exists || guide.exists else {
            capture(app, "reader-never-ready")
            return app.descendants(matching: .any)["screen.reader"].exists
                ? "the reader opened but drew no page within \(Int(timeout)) s"
                : "the reader never opened"
        }
        // The page and the guide arrive together, near enough: a short wait
        // for a guide that is a moment behind the page.
        if let failure = dismissGuide(app, waitingUpTo: 5) { return failure }
        // Back in the tree once the guide has gone.
        guard page.waitForExistence(timeout: 10) else {
            capture(app, "reader-no-page")
            return "the reading guide went, and no page was under it"
        }
        return nil
    }

    /// The reader's first-run guide, by what it says: its combined label
    /// starts with the zones' headline or the narration tip's.
    private func readingGuide(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                "Reading gestures", "This book is narrated"))
            .firstMatch
    }

    /// Dismisses the guide, the way a reader does — a tap anywhere on it —
    /// if it is up or comes up within `wait`. The way
    /// `LocalBooksFlowTests` and `LayoutSweepTests.testReaderScreen` do.
    ///
    /// - Returns: nil when no guide is left on screen, else why.
    private func dismissGuide(_ app: XCUIApplication, waitingUpTo wait: TimeInterval) -> String? {
        let guide = readingGuide(app)
        guard guide.exists || guide.waitForExistence(timeout: wait) else { return nil }
        capture(app, "guide")
        // The guide takes the tap itself, so this turns no page.
        guide.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        guard guide.waitForNonExistence(timeout: 10) else {
            capture(app, "guide-stuck")
            return "the reading guide did not go away when tapped"
        }
        return nil
    }

    /// The reader's Back button on screen and hittable, showing the bars
    /// with a tap in the middle of the page if they have hidden.
    private func showBars(_ app: XCUIApplication) -> Bool {
        let back = app.buttons["Back to the book"].firstMatch
        if back.waitForExistence(timeout: 5), back.isHittable { return true }
        // The middle of the page toggles the bars; the edges would turn it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return back.waitForExistence(timeout: 5) && back.isHittable
    }

    /// Closes the reader with its Back button and checks it went.
    ///
    /// The reader's own screen has to be gone, not just something under it
    /// present: a tab and its pages stay in the tree under the reader's
    /// cover, so finding one says nothing about whether the close worked.
    ///
    /// - Returns: nil once the reader has gone, else what went wrong.
    private func closeReader(_ app: XCUIApplication) -> String? {
        // A guide that came up late would take the close's tap itself.
        if let failure = dismissGuide(app, waitingUpTo: 0) { return failure }
        guard showBars(app) else {
            capture(app, "close-no-bars")
            return "no Back to the book button to close the reader with"
        }
        app.buttons["Back to the book"].firstMatch.tap()
        let reader = app.descendants(matching: .any)["screen.reader"]
        guard reader.waitForNonExistence(timeout: 15) else {
            capture(app, "reader-not-closed")
            return readingGuide(app).exists
                ? "the reader did not close: the reading guide took the tap"
                : "the reader did not close: Back to the book left it on screen"
        }
        return nil
    }

    /// Selects a tab by its label; see `LayoutSweepTests.selectTab` for why
    /// the bar is not assumed.
    private func selectTab(_ title: String, in app: XCUIApplication) {
        let inBar = app.tabBars.buttons[title].firstMatch
        let target = inBar.exists ? inBar : app.buttons[title].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 30), "no \(title) tab")
        target.tap()
    }

    /// Writes one verdict line for the script's summary, and asserts it, so
    /// the run's own result and the summary cannot disagree.
    private func record(_ check: String, _ passed: Bool, _ detail: String) {
        let line = "\(check) \(passed ? "PASS" : "FAIL") \(detail)\n"
        let url = out.appendingPathComponent("checks.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            _ = write(line, to: "checks.txt")
        }
        XCTAssertTrue(passed, "\(check): \(detail)")
    }

    /// Atomic, because the script's approver polls for `code.txt` and must
    /// never read half a code.
    @discardableResult
    private func write(_ text: String, to name: String) -> Bool {
        (try? Data(text.utf8).write(to: out.appendingPathComponent(name), options: .atomic)) != nil
    }

    /// A numbered PNG in the output folder, so the files sort in the order the
    /// run took them.
    private func capture(_ app: XCUIApplication, _ name: String) {
        shots += 1
        let file = String(format: "%02d-%@.png", shots, name)
        try? app.screenshot().pngRepresentation.write(to: out.appendingPathComponent(file))
    }
}
