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

    /// Only the controls that surface actually exposes, and that this app can
    /// actually make fire.
    ///
    /// The wheel belongs on the phone's list too, even though the phone has no
    /// wheel: `nextTrack` / `previousTrack` is where AirPods' double- and
    /// triple-press arrive, and where a Bluetooth head unit's buttons arrive.
    /// Leaving the rows out meant the binding those controls actually use was
    /// invisible and unchangeable.
    ///
    /// `.doubleTapForward`/`.doubleTapBackward`/`.holdForward`/`.holdBackward`
    /// are deliberately absent everywhere. `RemoteCommandCenter` never fires
    /// them — `MPRemoteCommandCenter` has no command representing a double tap
    /// distinct from `nextTrack`/`previousTrack`, which `wheelNext`/
    /// `wheelPrevious` already cover, and nothing routes a hold through the
    /// bindings either. They used to be offered here anyway, so rebinding one
    /// silently did nothing — a setting that cannot be wrong because it is
    /// never consulted. See `PlaybackControl` for what a real "hold" would need.
    ///
    /// Headphones list only the wheel for the same reason: a headphone's single
    /// press arrives as `togglePlayPauseCommand`, which is play/pause by the
    /// system's contract and never consults a binding — only the double- and
    /// triple-press, which land on the track commands, reach this surface. The
    /// wheel rows are resolved against it whenever a headphone-class device is
    /// the audio route; see `RemoteCommandCenter.surface(for:active:headphonesRouted:)`.
    private var controls: [PlaybackControl] {
        switch surface {
        case .phone:
            [.tapForward, .tapBackward, .wheelNext, .wheelPrevious]
        case .carPlay:
            [.tapForward, .tapBackward, .wheelNext, .wheelPrevious]
        case .headphones:
            [.wheelNext, .wheelPrevious]
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

            Section {
                ForEach(controls, id: \.self) { control in
                    Picker(control.title, selection: binding(for: control)) {
                        ForEach(actions(for: control), id: \.self) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("Buttons")
            } footer: {
                // Worth saying, because it is the one binding with a visible
                // side effect elsewhere: iOS draws the skip buttons only while
                // nothing claims the track buttons.
                if surface != .carPlay {
                    Text(wheelIsBound
                        ? "The Lock Screen shows next and previous track while the wheel is assigned."
                        : "Leave the wheel unassigned and the Lock Screen shows the skip buttons instead.")
                }
            }
            .listRowBackground(Palette.surface)

            Section {
                ValueStepper(
                    "Forward", value: $settings.commandMap.skipForwardInterval,
                    in: 5 ... 120, step: 5, format: { "\(Int($0))s" },
                )
                ValueStepper(
                    "Back", value: $settings.commandMap.skipBackwardInterval,
                    in: 5 ... 120, step: 5, format: { "\(Int($0))s" },
                )
            } header: {
                Text("Skip amount")
            } footer: {
                // One setting, three places: this is also what the jump buttons
                // beside the chapter name on the reading page move by.
                Text("Used by the skip buttons wherever narration is playing — the player, the Lock Screen, CarPlay — and by the jump buttons next to the chapter name on the reading page.")
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

    private var wheelIsBound: Bool {
        settings.commandMap.usesTrackCommands(on: surface)
    }

    /// What the picker offers: the assignable actions, plus whatever this
    /// control is already bound to. The addition matters for a reader carrying
    /// a binding no longer on offer — `.sleepTimer` was pickable back when
    /// nothing performed it — whose row would otherwise draw with no selection.
    private func actions(for control: PlaybackControl) -> [PlaybackAction] {
        let current = settings.commandMap.action(for: control, on: surface)
        var options = PlaybackAction.assignable
        if !options.contains(current) { options.append(current) }
        return options
    }

    private func binding(for control: PlaybackControl) -> Binding<PlaybackAction> {
        Binding(
            get: { settings.commandMap.action(for: control, on: surface) },
            set: { settings.commandMap.bind($0, to: control, on: surface) },
        )
    }
}
