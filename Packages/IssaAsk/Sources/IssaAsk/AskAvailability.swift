import Foundation
#if canImport(FoundationModels) && !os(tvOS)
import FoundationModels
#endif

/// Whether this machine can answer a question at all, and if not, why.
///
/// Four distinct answers rather than a Bool, because the settings screen says
/// something different for each and only one of them is the reader's to fix:
/// an ineligible device is a dead end, Apple Intelligence being switched off is
/// a trip to Settings, and a model still downloading is a matter of waiting.
/// Collapsing them into "unavailable" is how a reader ends up believing the
/// feature is broken when it is three minutes from working.
public enum AskAvailability: Sendable, Hashable {
    case available
    /// The device is eligible but Apple Intelligence has not been turned on.
    case appleIntelligenceOff
    /// Eligible and on; the model is still coming down.
    case modelDownloading
    /// This hardware will never run it.
    case unsupportedDevice
    /// Apple TV. The 27 SDK ships the framework, with every symbol in it
    /// marked unavailable there, so there is nothing to ask either way.
    case unsupportedOnThisPlatform

    /// Whether a question can be asked right now. `modelDownloading` is *not*
    /// ready: the toggle stays usable so the reader can turn the feature on and
    /// have it work later, but a question asked now fails.
    public var isReady: Bool { self == .available }

    #if canImport(FoundationModels) && !os(tvOS)
    /// Read fresh every time rather than cached: the reader may have gone to
    /// Settings and turned Apple Intelligence on since the app launched, which
    /// is exactly the moment the copy on screen has to change.
    public static func current() -> AskAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            .available
        case .unavailable(.appleIntelligenceNotEnabled):
            .appleIntelligenceOff
        case .unavailable(.modelNotReady):
            .modelDownloading
        case .unavailable:
            // Including whatever reason a later OS adds: an unknown reason the
            // reader cannot act on reads best as "not on this device".
            .unsupportedDevice
        }
    }
    #else
    /// tvOS. The 27 SDK ships the framework, but every symbol in it is marked
    /// unavailable there, so there is still nothing to ask — and `canImport`
    /// alone no longer says so, which is why the guard names the platform too.
    public static func current() -> AskAvailability { .unsupportedOnThisPlatform }
    #endif
}

// MARK: - Apple's servers

/// The reader's daily allowance of answers from Apple's servers, in terms the
/// app can hold without importing FoundationModels.
public struct CloudQuota: Sendable, Hashable {
    public var isLimitReached: Bool
    public var isApproachingLimit: Bool
    /// When the allowance resets, when Apple says.
    public var resetDate: Date?

    public init(isLimitReached: Bool, isApproachingLimit: Bool, resetDate: Date?) {
        self.isLimitReached = isLimitReached
        self.isApproachingLimit = isApproachingLimit
        self.resetDate = resetDate
    }
}

/// Whether "Use Apple's servers" can be offered, and in what state.
///
/// Separate from `AskAvailability` because Ask itself stays gated on the
/// on-device model: Apple's servers are an option inside Ask, never a way to
/// have Ask where the device cannot run it.
public enum CloudAvailability: Sendable, Hashable {
    /// Offer the switch.
    case available(CloudQuota)
    /// Offer it, but disabled, with when the allowance comes back.
    case limitReached(resetDate: Date?)
    /// Not offered: the OS is older than 27, the device isn't eligible, the
    /// system isn't ready, the build doesn't carry the entitlement, or this is
    /// Apple TV.
    case unavailable(reason: String)

    /// Whether the switch appears at all.
    public var offersSwitch: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// Whether the switch can be turned on right now.
    public var isUsable: Bool {
        if case .available = self { return true }
        return false
    }

    #if canImport(FoundationModels) && !os(tvOS)
    /// Read fresh every time: the allowance and the system's readiness both
    /// change while the app is open.
    public static func current() -> CloudAvailability {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else {
            return .unavailable(reason: "os")
        }
        guard Entitlements.allowsPrivateCloudCompute else {
            return .unavailable(reason: "entitlement")
        }
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            let quota = CloudQuota(model.quotaUsage)
            return quota.isLimitReached ? .limitReached(resetDate: quota.resetDate) : .available(quota)
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "deviceNotEligible")
        case .unavailable(.systemNotReady):
            return .unavailable(reason: "systemNotReady")
        case .unavailable:
            return .unavailable(reason: "unknown")
        }
    }
    #else
    public static func current() -> CloudAvailability { .unavailable(reason: "platform") }
    #endif
}
