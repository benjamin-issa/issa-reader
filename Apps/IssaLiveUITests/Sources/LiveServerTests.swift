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
        let stillIn = !signedOut(app)
        record("sessionAtEnd", stillIn, stillIn ? "still signed in" : "signed out by the end of the run")
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
        let survived = !signedOut(app)
        record("session", survived, survived ? "still signed in 30 s after the covers" : "signed out while covers loaded")
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
        guard let expected = setting("E2E_STATUS_LABEL"), let title = setting("E2E_STATUS_TITLE") else {
            record("statusLabel", true, "skipped: no status book given")
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
    /// Only the reader's arrival is judged here. Whether the position reached
    /// the server — and, on 3.x, whether it filed a book that had no status —
    /// is the script's to check over the API afterwards: two seconds of
    /// debounce and a queue drain happen after the last tap, and nothing on
    /// screen says they finished.
    private func readAPage(_ app: XCUIApplication) {
        guard let book = setting("E2E_READ_BOOK") else {
            record("readerOpened", true, "skipped: no book to read given")
            return
        }
        guard openReader(app, book: book) else {
            record("readerOpened", false, "the reader never opened \(book)")
            return
        }
        capture(app, "reader")
        for _ in 0 ..< 3 {
            // The right edge turns forward; the middle would toggle the bars.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        Thread.sleep(forTimeInterval: 15)
        capture(app, "reader-turned")
        record("readerOpened", true, "opened and turned three pages")
    }

    /// Plays a read-along past the end of its first audio file.
    ///
    /// The Gap Book's first file ends in an after-hole, audio that runs on past
    /// the file's last sentence: the crossing 1.3.0 had to fix, and the one a
    /// coordinator that misreads a file's end would stop or loop at. Still
    /// playing well past it is the check. It plays through the Mac's
    /// speakers, which is why the script asks for `--audio` explicitly.
    private func readAlong(_ app: XCUIApplication) {
        guard let book = setting("E2E_READALONG_BOOK") else {
            record("readAlong", false, "--audio given but no read-along book")
            return
        }
        // The narrated book is a larger download than a plain EPUB.
        guard openReader(app, book: book, timeout: 240) else {
            record("readAlong", false, "the reader never opened \(book)")
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

    /// Opens a book by the same link a widget uses, and dismisses the
    /// first-run guide if it comes up.
    ///
    /// `open` relaunches the app with the URL. The guide is modal to
    /// accessibility, so while it shows, the reader's own bars are not in the
    /// tree at all — which is why either one counts as arrived.
    private func openReader(_ app: XCUIApplication, book: String, timeout: TimeInterval = 120) -> Bool {
        guard let url = URL(string: "issareader://book/\(book)") else { return false }
        app.open(url)
        let back = app.buttons["Back to the book"].firstMatch
        let coach = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                "Reading gestures", "This book is narrated"))
            .firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !back.exists, !coach.exists {
            Thread.sleep(forTimeInterval: 1)
        }
        if coach.exists {
            capture(app, "coach")
            // The guide takes the tap itself, so this turns no page.
            coach.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        if back.waitForExistence(timeout: 5) { return true }
        // The bars may have hidden; the middle of the page brings them back.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return back.waitForExistence(timeout: 5)
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
