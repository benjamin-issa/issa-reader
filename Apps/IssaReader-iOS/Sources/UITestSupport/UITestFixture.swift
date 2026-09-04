#if ISSA_UITEST_FIXTURE
import Foundation
import IssaCore

/// Puts the app in front of a stub server for the layout sweep.
///
/// Three things keep this out of a shipping build, and only the first is
/// structural. `project.yml` sets `EXCLUDED_SOURCE_FILE_NAMES` for this
/// directory on Release, so the compiler is never handed these files and no
/// textual condition can leak them. `ISSA_UITEST_FIXTURE` then keeps the
/// fixture out of an ordinary Debug build — note it is defined over exactly
/// the configurations `DEBUG` covers, so on its own it is `#if DEBUG` under
/// another name and was wrongly described here as an independent second gate.
/// And it does nothing unless a launch **argument** asks for it, which only
/// whoever launches the process can set.
///
/// `scripts/release.sh` greps the archived binary for the argument string below
/// and fails the release if it finds it — and proves that grep can fire before
/// trusting it, which it could not for the first two builds it guarded.
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
        // `register(defaults:)`, not `set(_:forKey:)`. `AppModel.init` reads
        // this key, so the fixture does have to supply it — but the
        // registration domain is volatile, so nothing is written to the app's
        // preferences and a later ordinary launch has no trace of the stub. The
        // previous `set` persisted: run the sweep with `--keep-devices`, then
        // launch the app by hand, and it would still be pointed at a host that
        // does not resolve, over cleartext, with ATS permitting it.
        //
        // It also sits below NSArgumentDomain in the lookup order, so
        // `LayoutSweepTests`' `-issa.lastServer ""` still wins where it wants
        // the signed-out screen.
        UserDefaults.standard.register(defaults: ["issa.lastServer": server])
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
