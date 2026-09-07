#if canImport(FoundationModels)
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
    /// The framework does not exist here at all — Apple TV.
    case unsupportedOnThisPlatform

    /// Whether a question can be asked right now. `modelDownloading` is *not*
    /// ready: the toggle stays usable so the reader can turn the feature on and
    /// have it work later, but a question asked now fails.
    public var isReady: Bool { self == .available }

    #if canImport(FoundationModels)
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
    /// tvOS. FoundationModels is not in the SDK, so there is nothing to ask.
    public static func current() -> AskAvailability { .unsupportedOnThisPlatform }
    #endif
}
