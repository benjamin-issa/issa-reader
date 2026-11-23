import UIKit
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
        readingPage(app)

        let end = signedIn(app)
        record("sessionAtEnd", end.passed, end.detail)
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
        let survived = signedIn(app)
        record("session", survived.passed, survived.passed
            ? "still signed in 30 s after the covers" : "while covers loaded: \(survived.detail)")
    }

    /// tvOS lists Advanced's rows inline, under a heading, so the row is
    /// reached by moving focus down the list until the lazy list has drawn it.
    ///
    /// On the way down Settings is photographed with focus at the top, on a
    /// middle row, in Advanced and on the last row, in the dark appearance a
    /// television is usually in; and the middle and the last row are measured
    /// for the focus highlight, which no accessibility query can see.
    private func serverVersion(_ app: XCUIApplication) {
        guard focusTab("Settings", in: app) else {
            record("serverVersion", false, "could not reach the Settings tab")
            return
        }
        // Dark, where the fault showed: a row background drawn over the focus
        // platter left the focused row dark, its label darkened for a light
        // platter, and only slivers of the platter above and below it. In the
        // light appearance the surface is so nearly the platter's white that
        // the same fault cannot be measured. Put back as it was afterwards.
        let appearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = appearance }
        Thread.sleep(forTimeInterval: 1.5)
        capture(app, "settings-top")
        // The first control is the Progress bar picker, which has to say what
        // it is and what it is set to: tvOS drew a bare segmented control,
        // whose focus landed on "Current chapter" with nothing naming it.
        let top = focusedLabel(app)
        let scopes = ["Current chapter", "Whole book"]
        // What the row says, to VoiceOver and to this test alike: its label,
        // its value, and the texts the tree holds on its line.
        let said = ([top, focusedValue(app)] + textsOnFocusedRow(app)).filter { !$0.isEmpty }
        record("progressBarRow",
               top.contains("Progress bar") && scopes.contains { scope in said.contains { $0.contains(scope) } },
               "the first control says \(said)")
        var visited = [top]
        // The version row is text, which focus passes over, so focus is walked
        // to the bottom of the list, where Sign out is the last control. The
        // list draws a row a little before it scrolls into view, and stopping
        // as soon as the row existed left it just off the bottom of the
        // screenshot. Nothing is selected on the way.
        let row = app.descendants(matching: .any)["settings.serverVersion"]
        let atBottom = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true AND label == %@", "Sign out"))
            .firstMatch
        var middle = false
        var advanced = false
        for _ in 0 ..< 24 where !(row.exists && atBottom.exists) {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.8)
            let label = focusedLabel(app)
            if visited.last != label { visited.append(label) }
            // A middle row of the list: neither its first control nor its last.
            if !middle, label.hasPrefix("Reading & highlights") {
                middle = true
                capture(app, "settings-middle")
                focusHighlight(app, "focusMiddleRow")
            }
            if !advanced, label.hasPrefix("Logs") {
                advanced = true
                capture(app, "settings-advanced")
            }
        }
        if !middle { record("focusMiddleRow", false, "focus never reached Reading & highlights") }
        // A television's remote is not rebound here, so Settings has no row
        // for it.
        record("noControlsRow", !visited.contains { $0.hasPrefix("Controls") },
               "focus went " + visited.map { "\"\($0)\"" }.joined(separator: ", "))
        capture(app, "settings")
        if atBottom.exists {
            focusHighlight(app, "focusLastRow")
        } else {
            record("focusLastRow", false, "focus never reached Sign out")
        }
        guard row.exists else {
            record("serverVersion", false, "no Server version row in Settings")
            return
        }
        // The value, wherever the row keeps it: its own value, the end of a
        // combined label, or a text of its own on the row's line, which is
        // where it is now that the row is a stop the remote can land on.
        let onLine = app.staticTexts.allElementsBoundByIndex
            .filter { abs($0.frame.midY - row.frame.midY) < row.frame.height / 2 }
            .map(\.label).filter { $0 != "Server version" }
        let combined = row.label.replacingOccurrences(of: "Server version, ", with: "")
        let shown = (row.value as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (combined == "Server version" || combined.isEmpty ? onLine.first ?? combined : combined)
        guard let expected = setting("E2E_EXPECT_VERSION") else {
            record("serverVersion", true, "shows \"\(shown)\" (nothing expected)")
            return
        }
        record("serverVersion", shown == expected, "shows \"\(shown)\", expected \"\(expected)\"")
    }

    /// The Reading & highlights page, photographed for the record and left
    /// with Menu. After every check, so a walk that goes astray here cannot
    /// take one of them with it.
    private func readingPage(_ app: XCUIApplication) {
        let appearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = appearance }
        for _ in 0 ..< 16 where !focusedLabel(app).hasPrefix("Reading & highlights") {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.6)
        }
        guard focusedLabel(app).hasPrefix("Reading & highlights") else { return }
        remote.press(.select)
        Thread.sleep(forTimeInterval: 2)
        capture(app, "reading-page")
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.8)
        capture(app, "reading-page-down")
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 1.5)
    }

    // MARK: - The focus highlight

    /// The label of whatever has focus, or "" when nothing does.
    private func focusedLabel(_ app: XCUIApplication) -> String {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return focused.exists ? focused.label : ""
    }

    /// The focused element's accessibility value, or "".
    private func focusedValue(_ app: XCUIApplication) -> String {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return focused.exists ? (focused.value as? String) ?? "" : ""
    }

    /// The texts drawn on the focused row's line, wherever the tree puts
    /// them: a picker row's value is not a child of the focused element.
    private func textsOnFocusedRow(_ app: XCUIApplication) -> [String] {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard focused.exists else { return [] }
        let row = focused.frame
        return app.staticTexts.allElementsBoundByIndex
            .filter { abs($0.frame.midY - row.midY) < row.height / 2 }
            .map(\.label)
    }

    /// Whether the focused row is drawn as one highlight.
    ///
    /// The fault, on a television in the dark appearance: a list row that
    /// paints its own background drew it over the system's focus platter. The
    /// focused row stayed the resting surface's near-black, its label turned
    /// dark for a platter nobody could see, and the platter showed only as two
    /// bright slivers above and below the row. So the row is sampled where no
    /// text is (past the middle of its width) at its centre and near its top
    /// and bottom edges: lit, all three, and alike, is one highlight.
    private func focusHighlight(_ app: XCUIApplication, _ check: String) {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard focused.exists else {
            record(check, false, "nothing has focus")
            return
        }
        let label = focused.label
        let frame = focused.frame
        let shot = app.screenshot()
        guard let image = shot.image.cgImage, let pixels = Pixels(image) else {
            record(check, false, "could not read the screenshot")
            return
        }
        // Points to pixels: the screenshot is the whole screen.
        let scale = CGFloat(image.width) / shot.image.size.width
        let x = (frame.minX + frame.width * 0.62) * scale
        let inset = frame.height * 0.18
        let samples = [frame.minY + inset, frame.midY, frame.maxY - inset].map { y in
            pixels.luminance(x: Int(x), y: Int(y * scale))
        }
        // And the label legible on it: the darkest pixel across the start of
        // the row, where the title is, against the platter. A destructive
        // title kept the dark appearance's light red, pale pink on white.
        var ink = 1.0
        for offset in [-0.12, 0, 0.12] {
            let y = Int((frame.midY + frame.height * offset) * scale)
            for x in Int((frame.minX + frame.width * 0.005) * scale) ..< Int((frame.minX + frame.width * 0.3) * scale) {
                ink = min(ink, pixels.luminance(x: x, y: y))
            }
        }
        let contrast = (samples[1] + 0.05) / (ink + 0.05)
        let detail = String(
            format: "\"%@\" at %.0f,%.0f %.0f×%.0f: luminance top %.2f, centre %.2f, bottom %.2f; label %.2f, contrast %.1f",
            label, frame.minX, frame.minY, frame.width, frame.height, samples[0], samples[1], samples[2],
            ink, contrast)
        _ = write(detail + "\n", to: "\(check).txt")
        let lit = samples.allSatisfy { $0 > 0.6 }
        let even = (samples.max() ?? 0) - (samples.min() ?? 0) < 0.15
        let legible = contrast >= 3
        record(check, lit && even && legible, lit && even && legible
            ? "the focused row is one highlight with a legible label (\(detail))"
            : "the focused row is not one highlight with a legible label (\(detail))")
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

    /// Signed in, on positive evidence: the app in the foreground on one of
    /// its signed-in screens. "No code on screen" alone passed over an app
    /// that had crashed or quit, which shows no code either.
    private func signedIn(_ app: XCUIApplication) -> (passed: Bool, detail: String) {
        guard app.state == .runningForeground else {
            return (false, "the app is not running in the foreground (state \(app.state.rawValue))")
        }
        if signedOut(app) { return (false, "signed out") }
        guard isLanded(app) || app.descendants(matching: .any)["screen.settings"].exists else {
            return (false, "no signed-in screen on show")
        }
        return (true, "still signed in")
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

/// A screenshot's pixels, as 8-bit RGBA in a buffer of known layout.
private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        bytes = buffer
    }

    /// Relative luminance from 0 to 1 at a pixel, counted from the top left;
    /// 0 outside the image.
    func luminance(x: Int, y: Int) -> Double {
        guard (0 ..< width).contains(x), (0 ..< height).contains(y) else { return 0 }
        let i = (y * width + x) * 4
        let r = Double(bytes[i]) / 255, g = Double(bytes[i + 1]) / 255, b = Double(bytes[i + 2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
