import Foundation
import Testing

@testable import IssaReader_iOS

/// Whether a launch removes a token that was in the keychain before it, judged
/// as a decision over what the launch can see. The one that must never be wrong
/// is the update from a build that wrote no marker, which looks like a fresh
/// install except that its defaults hold the server address.
@Suite("A token left by an earlier install")
struct InstallMarkerTests {
    private func decide(
        isMainApp: Bool = true, isMac: Bool = false, hasMarker: Bool = false,
        hasEarlierUse: Bool = false, hasToken: Bool = false,
    ) -> InstallMarker.Decision {
        InstallMarker.decide(
            isMainApp: isMainApp, isMac: isMac, hasMarker: hasMarker,
            hasEarlierUse: hasEarlierUse, hasToken: hasToken)
    }

    @Test("a fresh install that finds a token removes it, and marks itself")
    func freshInstallWithStaleToken() {
        #expect(decide(hasToken: true) == .init(purgesToken: true, writesMarker: true))
    }

    @Test("an update from a build with no marker keeps the reader signed in")
    func updateKeepsTheToken() {
        #expect(decide(hasEarlierUse: true, hasToken: true) == .init(purgesToken: false, writesMarker: true))
    }

    @Test("a fresh install with no token has nothing to remove")
    func signedOutInstall() {
        #expect(decide() == .init(purgesToken: false, writesMarker: true))
    }

    @Test("a later launch does nothing")
    func markedInstall() {
        #expect(decide(hasMarker: true, hasToken: true) == .init(purgesToken: false, writesMarker: false))
    }

    @Test("a widget or other extension never removes a token or writes the marker")
    func extensionNeverActs() {
        #expect(decide(isMainApp: false, hasToken: true) == .init(purgesToken: false, writesMarker: false))
        #expect(decide(isMainApp: false) == .init(purgesToken: false, writesMarker: false))
    }

    @Test("the Mac, whose preferences outlive the app, never removes a token")
    func macNeverPurges() {
        #expect(decide(isMac: true, hasToken: true) == .init(purgesToken: false, writesMarker: true))
    }

    @Test("the stored server address is what says an earlier run was here")
    func earlierUseIsTheServerAddress() throws {
        let name = "install-marker-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!InstallMarker.hasEarlierUse(defaults))
        // The key the app itself stores the address under, not a copy of it.
        defaults.set("", forKey: AppModel.lastServerKey)
        #expect(!InstallMarker.hasEarlierUse(defaults), "an empty address is no address")
        defaults.set("https://library.example", forKey: AppModel.lastServerKey)
        #expect(InstallMarker.hasEarlierUse(defaults))
    }

    @Test("storage that is not the keychain is left alone")
    func settleIgnoresOtherStorage() throws {
        let name = "install-marker-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        InstallMarker.settle(LifecycleTokens(), defaults: defaults)
        #expect(!defaults.bool(forKey: InstallMarker.key))
    }
}
