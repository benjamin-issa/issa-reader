#if !os(tvOS)
import IssaAsk
import IssaUI
import SwiftUI

/// The switch, and the one honest sentence under it.
///
/// A different sentence for each state of the device rather than one
/// "unavailable", because only one of the three ways this can be unavailable is
/// the reader's to fix, and collapsing them into one is how somebody comes to
/// believe the feature is broken when it is three minutes from working.
///
/// The switch is there, and moves, whenever the device could answer at all.
/// Ask is on by default, so a reader whose Apple Intelligence is off or still
/// downloading is looking at a sparkle that cannot answer yet — and this switch
/// is their only way to make it go away. Only a device that can never answer
/// has no switch, because it has no sparkle either.
struct AskSettingsSection: View {
    @Environment(PlaybackSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var availability = AskAvailability.current()

    var body: some View {
        @Bindable var settings = settings

        return SettingsSection(note: Self.footer(for: availability)) {
            if Self.offersSwitch(for: availability) {
                Toggle(AskDevice.switchTitle, isOn: $settings.askEnabled)
                    .accessibilityIdentifier("settings.ask.toggle")
            }
        } header: {
            HStack(spacing: Metrics.spacing8) {
                Text("Ask AI about this book")
                BetaPill()
            }
        }
        .listRowBackground(Palette.surface)
        // Re-read when the app comes forward: the reader may have just been to
        // Settings to turn Apple Intelligence on, and this screen is where they
        // came back to.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { availability = AskAvailability.current() }
        }
    }

    /// Whether the switch is drawn: whenever the device could answer at all.
    ///
    /// Static and pure so a test can hold it to that. It used to be disabled
    /// while Apple Intelligence was off, which was fair while Ask was off until
    /// somebody turned it on; now that it is on from the start, the same
    /// disabled switch would leave that reader a sparkle they cannot remove.
    static func offersSwitch(for availability: AskAvailability) -> Bool {
        switch availability {
        case .available, .modelDownloading, .appleIntelligenceOff: true
        case .unsupportedDevice, .unsupportedOnThisPlatform: false
        }
    }

    static func footer(for availability: AskAvailability) -> String {
        switch availability {
        case .available:
            "Apple Intelligence answers on this \(AskDevice.noun); nothing leaves it. Issa Reader tries to limit the answer to only the parts of the book you have read, but can't guarantee it, and the model can produce incorrect answers."
        case .appleIntelligenceOff:
            "Apple Intelligence is turned off. \(AskDevice.turnOnSentence) Or turn this off to hide the button in the reader."
        case .modelDownloading:
            "Apple Intelligence is still downloading its model to this \(AskDevice.noun). Asking will work once it finishes. Or turn this off to hide the button in the reader."
        case .unsupportedDevice, .unsupportedOnThisPlatform:
            "This \(AskDevice.noun) doesn't support Apple Intelligence, so asking isn't available here."
        }
    }
}
#endif
