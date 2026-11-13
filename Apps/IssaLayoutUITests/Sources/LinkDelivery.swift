import XCTest

/// Sending a link to an app that is already running.
///
/// `XCUIApplication.open` relaunches the app, so a link meant to find a reader
/// open finds a fresh process. The link is sent by `xcrun simctl openurl`,
/// which a watcher on the host (`scripts/deliver-test-links.sh`) runs when a
/// test raises `flag` with the book's uuid in it. The sweep starts and stops
/// the watcher around the flow tests; by hand it is left running beside them.
extension XCTestCase {
    static let linkFlag = "/tmp/issa-test-link.flag"

    /// A run that has to be complete: a release run, or the sweep, which
    /// starts the watcher itself. There a missing watcher is a failure, not a
    /// skip, since a skipped flow test is a flow nobody checked.
    private var linkDeliveryIsRequired: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["ISSA_RELEASE_RUN"] == "1" || environment["ISSA_SWEEP"] == "1"
    }

    /// Takes down a flag nobody collected, so the next watcher does not send
    /// it as a link. Called from `tearDown`.
    func removeLinkFlag() {
        try? FileManager.default.removeItem(atPath: Self.linkFlag)
    }

    /// Delivers `issareader://book/<uuid>` to the running app, and answers the
    /// system's "Open in" prompt, which this route shows and a widget does not.
    func deliverLink(toBook uuid: String) throws {
        // Not a stale flag's link first.
        removeLinkFlag()
        try uuid.write(toFile: Self.linkFlag, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: Self.linkFlag), Date() < deadline { usleep(200_000) }
        if FileManager.default.fileExists(atPath: Self.linkFlag) {
            removeLinkFlag()
            let reason = "no watcher delivered the link: run scripts/deliver-test-links.sh"
            if linkDeliveryIsRequired {
                XCTFail(reason)
                return
            }
            throw XCTSkip(reason)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.alerts.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 20) { open.tap() }
    }
}
