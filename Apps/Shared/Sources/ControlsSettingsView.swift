import IssaPlayback
import IssaUI
import SwiftUI

/// Assign an action to each control, per surface.
///
/// The design puts this front and centre, and it is the feature that makes the
/// steering-wheel buttons genuinely useful: what `»` should do differs between
/// sitting on the sofa and driving.
public struct ControlsSettingsView: View {
    @Environment(PlaybackSettings.self) private var settings
    @State private var surface: ControlSurface = .phone

    public init() {}

    /// Only the controls that surface actually exposes. Offering a headphone
    /// double-tap binding for CarPlay would be noise.
    private var controls: [PlaybackControl] {
        switch surface {
        case .phone:
            [.tapForward, .tapBackward, .doubleTapForward, .doubleTapBackward, .holdForward, .holdBackward]
        case .carPlay:
            [.tapForward, .tapBackward, .wheelNext, .wheelPrevious, .holdForward, .holdBackward]
        case .headphones:
            [.tapForward, .doubleTapForward, .doubleTapBackward, .wheelNext, .wheelPrevious]
        }
    }

    public var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                Picker("Surface", selection: $surface) {
                    ForEach(ControlSurface.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Assign an action to each button. Bindings are per surface, so the wheel can mean something different in the car.")
            }
            .listRowBackground(Palette.surface)

            Section("Buttons") {
                ForEach(controls, id: \.self) { control in
                    Picker(control.title, selection: binding(for: control)) {
                        ForEach(PlaybackAction.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            .listRowBackground(Palette.surface)

            Section("Skip amount") {
                ValueStepper(
                    "Forward", value: $settings.commandMap.skipForwardInterval,
                    in: 5 ... 120, step: 5, format: { "\(Int($0))s" },
                )
                ValueStepper(
                    "Back", value: $settings.commandMap.skipBackwardInterval,
                    in: 5 ... 120, step: 5, format: { "\(Int($0))s" },
                )
            }
            .listRowBackground(Palette.surface)

            Section {
                Button("Reset \(surface.title) to defaults") {
                    settings.resetBindings(for: surface)
                }
            }
            .listRowBackground(Palette.surface)
        }
        .paperListBackground()
        .navigationTitle("Controls")
    }

    private func binding(for control: PlaybackControl) -> Binding<PlaybackAction> {
        Binding(
            get: { settings.commandMap.action(for: control, on: surface) },
            set: { settings.commandMap.bind($0, to: control, on: surface) },
        )
    }
}
