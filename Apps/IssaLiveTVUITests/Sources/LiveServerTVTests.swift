import XCTest

/// The live checks the television can run without anyone holding the remote:
/// pairing by device code, the library, the session outliving the covers, and
/// Settings' server version.
///
/// The phone's `LiveServerTests` explains the arrangement: the settings come
/// from `scripts/live-check.sh --platform tvos` as `TEST_RUNNER_E2E_*`, the
/// pairing code goes out through a file on the Mac, and the script approves it
/// and checks the server afterwards. Without `E2E_SERVER` the test skips.
///
/// Everything here moves by `XCUIRemote`, because that is the only way into a
/// tvOS app: nothing is tapped, focus is moved and selected. Of what the
/// phone's test also checks, the status label has no counterpart here — a
/// book opens straight into the read-along screen, which shows none — and a
/// page read and a read-along sit behind a poster grid and that screen, where
/// getting to one given book is a walk through focus rather than a query, so
/// those stay with the screen.
// `@MainActor` for the reason `LayoutSweepTests` gives: XCUITest's API is main
// actor isolated and this project builds with strict concurrency complete.
@MainActor
final class LiveServerTVTests: XCTestCase {
    /// One of the script's settings, or nil; empty counts as unset.
    /// `nonisolated` for `setUpWithError`, as in `LiveServerTests`.
    private nonisolated func setting(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    private nonisolated var out: URL {
        URL(fileURLWithPath: setting("E2E_OUT") ?? NSTemporaryDirectory())
    }

    private var shots = 0
    private var remote: XCUIRemote { XCUIRemote.shared }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            setting("E2E_SERVER") != nil,
            "needs a live server: run scripts/live-check.sh --platform tvos")
        continueAfterFailure = true
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    func testTheReleaseChecksAgainstALiveServer() throws {
        let server = try XCTUnwrap(setting("E2E_SERVER"))
        let app = XCUIApplication()
        // The server, in the arguments domain `UserDefaults` reads before the
        // app's own. A television that knows its server goes straight to a
        // code (`TVSignInView`), which spares typing an address with a remote
        // and needs nothing added to the app.
        app.launchArguments = ["-issa.lastServer", server]
        app.launch()

        let landed = pair(app)
        record("signIn", landed, landed ? signInMethod : "never reached the library")
        guard landed else { return }

        sessionSurvives(app)
        serverVersion(app)

        let stillIn = !signedOut(app)
        record("sessionAtEnd", stillIn, stillIn ? "still signed in" : "signed out by the end of the run")
    }

    // MARK: - Checks

    private var signInMethod = "already signed in"

    /// The code, handed to the script, until a signed-in screen appears.
    private func pair(_ app: XCUIApplication) -> Bool {
        let code = codeElement(app)
        var written = false
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            if isLanded(app) { return true }
            if !written, code.exists {
                written = write(code.label.replacingOccurrences(of: " ", with: ""), to: "code.txt")
                if written {
                    signInMethod = "paired with device code"
                    capture(app, "code")
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    private func sessionSurvives(_ app: XCUIApplication) {
        guard focusTab("Library", in: app) else {
            record("library", false, "could not reach the Library tab")
            return
        }
        // The books, not the screen: `screen.tvLibrary` is the scroll view
        // itself, there before a single book has arrived — it is what
        // `isLanded` has just seen — so waiting on it passed an empty shelf,
        // and the thirty seconds below then outlived no covers at all.
        //
        // A poster is waited for instead, as any button on the screen: each
        // one is a `NavigationLink`, and the shelf has no other control. Not
        // by the identifiers the phone's test uses. The television's tree
        // carries neither: the shelf's own `content.tvLibrary` takes the
        // place of `rail.continueReading`, and the grid's `cell.book.` posters
        // sit below the fold, where the lazy grid has not drawn them yet.
        let poster = app.descendants(matching: .any)["screen.tvLibrary"]
            .descendants(matching: .button).firstMatch
        let loaded = poster.waitForExistence(timeout: 90)
        record("library", loaded, loaded ? "the library shows its books" : "no book appeared on the shelf")
        Thread.sleep(forTimeInterval: 30)
        capture(app, "library")
        let survived = !signedOut(app)
        record("session", survived, survived ? "still signed in 30 s after the covers" : "signed out while covers loaded")
    }

    /// tvOS lists Advanced's rows inline, under a plain heading, so the row is
    /// reached by moving focus down the list until the lazy list has drawn it.
    private func serverVersion(_ app: XCUIApplication) {
        guard focusTab("Settings", in: app) else {
            record("serverVersion", false, "could not reach the Settings tab")
            return
        }
        // The version row is text, which focus passes over, so focus is walked
        // to the bottom of the list, where Sign out is the last control. The
        // list draws a row a little before it scrolls into view, and stopping
        // as soon as the row existed left it just off the bottom of the
        // screenshot. Nothing is selected on the way.
        let row = app.descendants(matching: .any)["settings.serverVersion"]
        let atBottom = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true AND label == %@", "Sign out"))
            .firstMatch
        for _ in 0 ..< 20 where !(row.exists && atBottom.exists) {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.5)
        }
        capture(app, "settings")
        guard row.exists else {
            record("serverVersion", false, "no Server version row in Settings")
            return
        }
        let shown = (row.value as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? row.label.replacingOccurrences(of: "Server version, ", with: "")
        guard let expected = setting("E2E_EXPECT_VERSION") else {
            record("serverVersion", true, "shows \"\(shown)\" (nothing expected)")
            return
        }
        record("serverVersion", shown == expected, "shows \"\(shown)\", expected \"\(expected)\"")
    }

    // MARK: - Helpers

    /// `DeviceCodeView` speaks the code a character at a time, which is also
    /// the only place it appears in the accessibility tree.
    private func codeElement(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@", "^[A-Z0-9]( [A-Z0-9-]){6,}$"))
            .firstMatch
    }

    private func isLanded(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["screen.reading"].exists
            || app.descendants(matching: .any)["screen.tvLibrary"].exists
    }

    /// Signed out, on a television, is a code on screen again: a TV that
    /// knows its server skips the form and starts a new pairing at once.
    private func signedOut(_ app: XCUIApplication) -> Bool {
        codeElement(app).exists || app.staticTexts["Sign in to your server"].exists
    }

    /// Moves focus up into the tab bar, then along it to `title`. A tab is
    /// chosen by focusing it; there is nothing to select.
    private func focusTab(_ title: String, in app: XCUIApplication) -> Bool {
        let tab = app.tabBars.buttons[title].firstMatch
        guard tab.waitForExistence(timeout: 30) else { return false }
        for _ in 0 ..< 8 where !app.tabBars.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.5)
        }
        let titles = ["Reading", "Library", "Listening", "Settings"]
        for _ in 0 ..< titles.count where !tab.hasFocus {
            let focused = app.tabBars.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
            let here = focused.exists ? titles.firstIndex(of: focused.label) ?? 0 : 0
            let there = titles.firstIndex(of: title) ?? 0
            remote.press(there > here ? .right : .left)
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard tab.hasFocus else { return false }
        // Down into the tab's content, so the list or grid under it has focus.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1)
        return true
    }

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

    @discardableResult
    private func write(_ text: String, to name: String) -> Bool {
        (try? Data(text.utf8).write(to: out.appendingPathComponent(name), options: .atomic)) != nil
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        shots += 1
        let file = String(format: "%02d-%@.png", shots, name)
        try? app.screenshot().pngRepresentation.write(to: out.appendingPathComponent(file))
    }
}
