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
    @Environment(AskCoordinator.self) private var coordinator
    @State private var availability = AskAvailability.current()
    @State private var cloud: CloudAvailability = .unavailable(reason: "not read yet")

    var body: some View {
        @Bindable var settings = settings
        let providers = coordinator.keys.registered
        let offersCloud = Self.offersCloudSwitch(
            availability: availability, cloud: cloud, askEnabled: settings.askEnabled,
        )
        let choices = AskDefaults.choices(
            registered: providers, deviceSupported: AskDefaults.supported(availability), cloudUsable: offersCloud,
        )

        return SettingsSection(note: Self.note(
            for: availability, askEnabled: settings.askEnabled, cloudOffered: offersCloud,
            providers: providers,
        )) {
            if Self.offersSwitch(for: availability) || !providers.isEmpty {
                Toggle(AskDevice.switchTitle, isOn: $settings.askEnabled)
                    .accessibilityIdentifier("settings.ask.toggle")
            }
            if providers.isEmpty {
                if offersCloud {
                    Toggle(Self.cloudSwitchTitle, isOn: $settings.askUsesAppleServers)
                        .accessibilityIdentifier("settings.ask.appleServers")
                }
            } else if settings.askEnabled, choices.count > 1 {
                // With a key of their own, the reader's default is one of every
                // place a question can go — still this device unless they
                // choose otherwise.
                Picker("Answer with", selection: defaultAnswerer(providers: providers, cloudOffered: offersCloud)) {
                    ForEach(choices, id: \.self) { answerer in
                        Text(AskDefaults.choiceTitle(answerer)).tag(answerer)
                    }
                }
                .accessibilityIdentifier("settings.ask.defaultAnswerer")
            }
            if offersCloud {
                Link(Self.cloudLinkTitle, destination: Self.privateCloudComputeURL)
                    .foregroundStyle(Palette.tangerine)
                    .accessibilityIdentifier("settings.ask.appleServers.link")
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
            if phase == .active {
                availability = coordinator.deviceAvailability()
                cloud = coordinator.cloudAvailability()
            }
        }
        .task {
            coordinator.keys.refresh()
            availability = coordinator.deviceAvailability()
            cloud = coordinator.cloudAvailability()
        }
    }

    /// The reader's default, as the picker shows it, and what choosing one
    /// writes back: Apple's servers by their own switch, a provider by name.
    private func defaultAnswerer(providers: [ProviderKind], cloudOffered: Bool) -> Binding<AskAnswerer> {
        Binding(
            get: {
                AskDefaults.answerer(
                    settings: settings, registered: providers,
                    deviceSupported: AskDefaults.supported(availability), cloudUsable: cloudOffered,
                )
            },
            set: { answerer in
                switch answerer {
                case .device:
                    settings.askUsesAppleServers = false
                    settings.askDefaultProvider = nil
                case .cloud:
                    settings.askUsesAppleServers = true
                    settings.askDefaultProvider = nil
                case .anthropic, .openAI:
                    settings.askDefaultProvider = answerer.provider?.rawValue
                }
            },
        )
    }

    /// The footer, with what a reader's own key changes.
    ///
    /// On a device that cannot run Apple Intelligence the key is the only
    /// thing that answers, so the footer says that rather than "isn't
    /// available here".
    static func note(
        for availability: AskAvailability, askEnabled: Bool, cloudOffered: Bool, providers: [ProviderKind],
    ) -> String {
        guard !providers.isEmpty else {
            return footer(for: availability, askEnabled: askEnabled, cloudOffered: cloudOffered)
        }
        switch availability {
        case .unsupportedDevice, .unsupportedOnThisPlatform:
            let names = ListFormatter.localizedString(byJoining: providers.map(\.displayName))
            return "This \(AskDevice.noun) can't run Apple Intelligence, so your questions go to \(names) with your own key, along with the book so far. Keys are in Settings › Advanced. The model can produce incorrect answers."
        default:
            return footer(for: availability, askEnabled: askEnabled, cloudOffered: cloudOffered)
                + providerSentence(providers)
        }
    }

    /// Said whenever a key is registered: where its questions go.
    static func providerSentence(_ providers: [ProviderKind]) -> String {
        guard !providers.isEmpty else { return "" }
        let names = ListFormatter.localizedString(byJoining: providers.map(\.displayName))
        return " With your own key, a question you send to \(names) goes there with the book so far, under your account. Keys are in Settings › Advanced."
    }

    static let cloudSwitchTitle = "Use Apple's servers by default"
    static let cloudLinkTitle = "About Private Cloud Compute"
    /// Apple's own explanation for readers rather than engineers: "Apple
    /// Intelligence & Privacy", whose Private Cloud Compute section says the
    /// data is processed only to fulfil the request and is not stored or made
    /// accessible to Apple. Checked to load on 19 Nov 2026; the security
    /// research blog says the same for an engineer.
    static let privateCloudComputeURL = URL(string: "https://www.apple.com/legal/privacy/data/en/intelligence-engine/")!

    /// Whether the default for Apple's servers is offered: only where Ask is on
    /// and can answer, and where this device and build can reach the servers.
    /// Offered while the allowance has run out, since it is a default for later.
    static func offersCloudSwitch(
        availability: AskAvailability, cloud: CloudAvailability, askEnabled: Bool,
    ) -> Bool {
        availability.isReady && askEnabled && cloud.offersSwitch
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

    private static let hideSentence = " Or turn this off to hide the button in the reader."

    /// The sentence under the switch.
    ///
    /// "Or turn this off to hide the button in the reader" is advice to a
    /// reader whose switch is on. Once they have turned it off there is no
    /// button to hide, and the footer would be telling them to do what they
    /// just did, so it leaves that sentence out when `askEnabled` is false.
    static func footer(
        for availability: AskAvailability, askEnabled: Bool, cloudOffered: Bool = false,
    ) -> String {
        switch availability {
        case .available where cloudOffered:
            "Apple Intelligence answers on this \(AskDevice.noun), and nothing leaves it. With “Use Apple's servers” on, here or for a single question, the question and the passages of the book needed to answer it go to Apple's Private Cloud Compute servers instead. Apple says they're used only for the answer, aren't stored, and can't be seen by anyone, including Apple. Either way, Issa Reader tries to limit the answer to only the parts of the book you have read, but can't guarantee it, and the model can produce incorrect answers."
        case .available:
            "Apple Intelligence answers on this \(AskDevice.noun); nothing leaves it. Issa Reader tries to limit the answer to only the parts of the book you have read, but can't guarantee it, and the model can produce incorrect answers."
        case .appleIntelligenceOff:
            "Apple Intelligence is turned off. \(AskDevice.turnOnSentence)" + (askEnabled ? hideSentence : "")
        case .modelDownloading:
            "Apple Intelligence is still downloading its model to this \(AskDevice.noun). Asking will work once it finishes." + (askEnabled ? hideSentence : "")
        case .unsupportedDevice, .unsupportedOnThisPlatform:
            "This \(AskDevice.noun) doesn't support Apple Intelligence, so asking isn't available here."
        }
    }
}
#endif
