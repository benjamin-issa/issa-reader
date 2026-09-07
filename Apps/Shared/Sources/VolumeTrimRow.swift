#if !os(tvOS)
import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

/// The one place a book's level is changed.
///
/// Both halves of the change have to happen together — the stored preference so
/// it survives the app, and the running player so it is audible while the
/// slider is still under the reader's thumb — and there are four callers: the
/// slider, its Reset button, and the Mac's ⌘⌥↑ and ⌘⌥↓ from two different
/// windows. Writing the pair by hand at each of them is how one of them ends up
/// silently persisting a level nothing plays at.
enum VolumeTrimControl {
    @MainActor
    static func set(
        _ decibels: Int, for book: Book,
        coordinator: (any PlaybackDriving)?, settings: PlaybackSettings,
    ) {
        let legal = VolumeTrim.clamped(decibels)
        settings.setVolumeTrim(legal, for: book.uuid)
        // Whatever is playing this book right now. Nil when nothing is, which
        // is a perfectly ordinary way to set a level in advance.
        coordinator?.player.gain = VolumeTrim.gain(legal)
    }

    /// Moves the level by one decibel, from wherever it is.
    ///
    /// Read from the preference rather than from the player: the player holds a
    /// gain, and going back and forth through the multiplier to recover a rung
    /// would accumulate the error the detents exist to prevent.
    @MainActor
    static func nudge(
        by delta: Int, for book: Book,
        coordinator: (any PlaybackDriving)?, settings: PlaybackSettings,
    ) {
        set(
            settings.volumeTrim(for: book.uuid) + delta,
            for: book, coordinator: coordinator, settings: settings,
        )
    }
}

// MARK: -

/// "Volume for this book" — the row under the transport.
///
/// Per book rather than global, because the problem it solves is a library
/// whose files disagree with each other: a self-hosted shelf is assembled from
/// whatever could be found, and one book being six decibels under the next is
/// not something a single app-wide setting can answer.
struct VolumeTrimRow: View {
    @Environment(PlaybackSettings.self) private var settings
    let book: Book
    let coordinator: (any PlaybackDriving)?

    private var trim: Int { settings.volumeTrim(for: book.uuid) }

    var body: some View {
        VStack(spacing: Metrics.spacing8) {
            HStack(spacing: Metrics.spacing12) {
                Text("Volume for this book")
                    .font(Typography.subhead)
                    .foregroundStyle(Palette.ink)
                Spacer()
                // Only once the book has departed from the recording. A reset
                // button beside "As recorded" would be a control that cannot do
                // anything, permanently.
                if trim != 0 {
                    Button("Reset") {
                        VolumeTrimControl.set(
                            0, for: book, coordinator: coordinator, settings: settings)
                    }
                    .buttonStyle(.plain)
                    .font(Typography.subhead)
                    .foregroundStyle(Palette.tangerine)
                    .accessibilityLabel("Reset volume for this book")
                }
                Text(VolumeTrim.label(trim))
                    // Monospaced digits so the value does not shuffle the row
                    // sideways as it steps through the rungs.
                    .font(Typography.subhead.monospacedDigit())
                    .foregroundStyle(Palette.inkSecondary)
            }

            Slider(
                value: Binding(
                    get: { Double(trim) },
                    set: { new in
                        VolumeTrimControl.set(
                            Int(new.rounded()), for: book,
                            coordinator: coordinator, settings: settings)
                    },
                ),
                in: Double(VolumeTrim.range.lowerBound) ... Double(VolumeTrim.range.upperBound),
                step: Double(VolumeTrim.step),
            )
            .tint(Palette.tangerine)
            // A tap at the centre detent, because "as recorded" is the value
            // the reader is most often trying to get back to and the track
            // gives no other sign of passing it.
            .sensoryFeedback(.impact(weight: .light), trigger: trim) { _, new in new == 0 }
            .accessibilityLabel("Volume for this book")
            // "−6 dB" is read as "minus six D B", which says nothing about
            // which way the sound moves.
            .accessibilityValue(VolumeTrim.spoken(trim))

            // Both ends read off the range rather than typed out, so widening
            // it cannot leave the slider going one place and its own ticks
            // still promising another.
            HStack {
                Text(VolumeTrim.label(VolumeTrim.range.lowerBound))
                Spacer()
                Text("as recorded")
                Spacer()
                Text(VolumeTrim.label(VolumeTrim.range.upperBound))
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.inkTertiary)
            // The slider says all three already; VoiceOver would otherwise read
            // the ticks as three more values to land on.
            .accessibilityHidden(true)
        }
        // Nothing to trim the level of. The preference could still be written,
        // but a control that changes something inaudible is a control that
        // looks broken.
        .disabled(coordinator == nil)
        .padding(.horizontal, Metrics.spacing8)
    }
}
#endif
