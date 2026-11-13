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
    /// The exit status of `simctl openurl` for the link, which the watcher
    /// writes once it has run it.
    static let linkAck = "/tmp/issa-test-link.ack"

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
        try? FileManager.default.removeItem(atPath: Self.linkAck)
    }

    /// Delivers `issareader://book/<uuid>` to the running app, and answers the
    /// system's "Open in" prompt, which this route shows and a widget does not.
    func deliverLink(toBook uuid: String) throws {
        // Not a stale flag's link first, nor a stale answer.
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

        // Whether the system took the link. The watcher takes the flag before
        // it runs `openurl`, so the flag going says nothing about that: a
        // simulator that is gone or an app that is not installed fails the
        // open, and the test then waited for a link that was never sent. After
        // the prompt, in case `openurl` waits on it.
        let answered = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: Self.linkAck), Date() < answered { usleep(200_000) }
        let status = (try? String(contentsOfFile: Self.linkAck, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if status != "0" {
            XCTFail("the link was not opened: simctl openurl answered \(status ?? "nothing")")
        }
    }
}
