#if ISSA_UITEST_FIXTURE
import Foundation
import IssaCore

/// Puts the app in front of a stub server for the layout sweep.
///
/// Two gates, and both must pass. The code compiles only under
/// `ISSA_UITEST_FIXTURE`, which `project.yml` sets on the Debug configuration
/// alone and names separately from `DEBUG` so that `#if DEBUG` is not the only
/// thing standing between this and a shipped build. And it does nothing unless
/// a launch **argument** asks for it — an argument can only be set by whoever
/// launches the process, unlike a `UserDefaults` key, which anything able to
/// write the app's preferences could set and which would survive relaunches.
///
/// `scripts/release.sh` greps the archived binary for the argument string below
/// and fails the release if it finds it, so a condition that drifts into the
/// wrong configuration fails the release rather than the review.
enum UITestFixture {
    static let argument = "-IssaUITestFixture"

    /// A scheme-qualified address, deliberately. `AppModel.firstReachable`
    /// probes with an ephemeral session, which does not consult `URLProtocol`'s
    /// global registry — but `ServerAddress.candidates` returns exactly one URL
    /// for anything containing `://`, and `firstReachable` skips the probe
    /// entirely when there is only one candidate.
    static let server = "http://\(FixtureServer.host)"

    /// Registers the stub and returns the pieces `AppModel` needs, or nil when
    /// this launch is an ordinary one.
    static func installIfRequested() -> (tokens: any TokenPersisting, server: String)? {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return nil }
        URLProtocol.registerClass(FixtureServer.self)
        UserDefaults.standard.set(server, forKey: "issa.lastServer")
        return (InMemoryTokens(), server)
    }
}

/// A token store that never touches the keychain.
private final class InMemoryTokens: TokenPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    init() {
        // A token, so `restore()` takes the signed-in path rather than the
        // sign-out one. The stub still checks for it on every request.
        stored[UITestFixture.server] = "fixture-token"
    }

    func read(account: String) -> String? { lock.withLock { stored[account] } }
    func write(_ token: String, account: String) { lock.withLock { stored[account] = token } }
    func delete(account: String) { _ = lock.withLock { stored.removeValue(forKey: account) } }
}
#endif
