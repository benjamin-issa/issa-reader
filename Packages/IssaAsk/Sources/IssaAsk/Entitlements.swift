import Foundation
#if os(macOS)
import Security
#endif

/// What this build was signed to do, where the answer is not otherwise visible.
enum Entitlements {
    static let privateCloudCompute = "com.apple.developer.private-cloud-compute"

    /// Whether this process carries the Private Cloud Compute entitlement.
    ///
    /// On the Mac the answer differs between builds of the same app: the App
    /// Store build carries it, while Debug signs with a Developer ID profile
    /// that Apple does not let grant it, and a `swift test` binary is not
    /// signed for anything. The model's own `availability` does not report a
    /// missing entitlement, so the switch would appear and every question fail.
    /// Read from the running task instead, once.
    ///
    /// On iOS and iPadOS every build that can run carries it (the App Store and
    /// development profiles both grant it, and the simulator embeds what the
    /// entitlements file claims), and the task API is not available there.
    static let allowsPrivateCloudCompute: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, privateCloudCompute as CFString, nil)
        return (value as? Bool) == true
        #else
        return true
        #endif
    }()
}
