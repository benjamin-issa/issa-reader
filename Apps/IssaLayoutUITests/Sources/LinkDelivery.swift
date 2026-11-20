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
        // The system's prompt, unless the open has already failed: a simulator
        // that is gone or an app that is not installed answers at once, and
        // there is no prompt to wait twenty seconds for then.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.alerts.buttons["Open"].firstMatch
        let prompted = Date().addingTimeInterval(20)
        while Date() < prompted {
            if open.exists { open.tap(); break }
            if let answer = linkAnswer(), !answer.hasPrefix("0 ") { break }
            usleep(300_000)
        }

        // Whether the system took the link, and which link the answer is for.
        // The watcher takes the flag before it runs `openurl`, so the flag going
        // says nothing about that, and an answer left by an earlier link must
        // not pass for this one. After the prompt, in case `openurl` waits on it.
        let answered = Date().addingTimeInterval(15)
        while linkAnswer() == nil, Date() < answered { usleep(200_000) }
        guard let answer = linkAnswer() else {
            XCTFail("the link was not opened: simctl openurl answered nothing")
            return
        }
        XCTAssertEqual(answer, "0 \(uuid)",
                       "the link was not opened, or the answer is for another link: simctl openurl answered \(answer)")
    }

    /// What the watcher wrote for the last link, "<status> <uuid>", or nil.
    private func linkAnswer() -> String? {
        (try? String(contentsOfFile: Self.linkAck, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
