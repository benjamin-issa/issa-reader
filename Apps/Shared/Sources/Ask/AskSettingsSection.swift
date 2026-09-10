#if !os(tvOS)
import IssaAsk
import IssaUI
import SwiftUI

/// The switch, and the one honest sentence under it.
///
/// Four different sections rather than one with a disabled toggle, because only
/// one of the three ways this can be unavailable is the reader's to fix, and
/// collapsing them into "unavailable" is how somebody comes to believe the
/// feature is broken when it is three minutes from working.
struct AskSettingsSection: View {
    @Environment(PlaybackSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var availability = AskAvailability.current()

    var body: some View {
        @Bindable var settings = settings

        return Section {
            switch availability {
            case .available, .modelDownloading:
                Toggle("Ask about your book", isOn: $settings.askEnabled)
                    .accessibilityIdentifier("settings.ask.toggle")
            case .appleIntelligenceOff:
                // Shown and disabled rather than hidden: the reader looking for
                // this needs to find it and be told why it will not move.
                Toggle("Ask about your book", isOn: $settings.askEnabled)
                    .disabled(true)
                    .accessibilityIdentifier("settings.ask.toggle")
            case .unsupportedDevice, .unsupportedOnThisPlatform:
                EmptyView()
            }
        } header: {
            HStack(spacing: Metrics.spacing8) {
                Text("Ask AI about this book")
                BetaPill()
            }
        } footer: {
            Text(footer)
                .settingsFooter()
        }
        .listRowBackground(Palette.surface)
        // Re-read when the app comes forward: the reader may have just been to
        // Settings to turn Apple Intelligence on, and this screen is where they
        // came back to.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { availability = AskAvailability.current() }
        }
    }

    private var footer: String {
        switch availability {
        case .available:
            "Apple Intelligence answers on this \(AskDevice.noun); nothing leaves it. Issa Reader tries to limit the answer to only the parts of the book you have read, but can't guarantee it, and the model can produce incorrect answers."
        case .appleIntelligenceOff:
            "Apple Intelligence is turned off. Turn it on in \(AskDevice.settingsPath), then come back."
        case .modelDownloading:
            "Apple Intelligence is still downloading its model to this \(AskDevice.noun). Asking will work once it finishes."
        case .unsupportedDevice, .unsupportedOnThisPlatform:
            "This \(AskDevice.noun) doesn't support Apple Intelligence, so asking isn't available here."
        }
    }
}
#endif
