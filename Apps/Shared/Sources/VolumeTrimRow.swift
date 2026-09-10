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
    /// Nil when nothing is playing this book, which is the case the whole row
    /// is disabled for. Otherwise the player's own answer.
    private var carriesGain: Bool? { coordinator?.player.tapCarriesGain }

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
            // which way the sound moves — and, where the louder half cannot be
            // delivered, VoiceOver has no caption to fall back on.
            .accessibilityValue(VolumeTrimReach.spoken(trim, carriesGain: carriesGain))

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

            // The adjacent case to the disable below, and the one that was
            // silent. This book has no tap, so `applyPlayerVolume` can only go
            // down and everything right of centre plays as recorded. Said
            // rather than disabled: the quieter half still works, and the level
            // is worth keeping for when the same book is played from a file.
            if let caption = VolumeTrimReach.caption(carriesGain: carriesGain) {
                Text(caption)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // VoiceOver hears it from the slider's own value instead,
                    // where the reader is when it matters.
                    .accessibilityHidden(true)
            }
        }
        // Nothing to trim the level of. The preference could still be written,
        // but a control that changes something inaudible is a control that
        // looks broken.
        .disabled(coordinator == nil)
        .padding(.horizontal, Metrics.spacing8)
    }
}

// MARK: -

/// What the volume row says about a level it cannot deliver.
///
/// **The half of the slider that does nothing, and used to say nothing.**
/// `AVPlayer.volume` is documented 0…1, so with no `MTAudioProcessingTap` on
/// the item `AudioPlayer.applyPlayerVolume` computes `volume * min(gain, 1)`:
/// the quieter half arrives, and everything right of "as recorded" plays at the
/// recorded level. The arithmetic is correct — there is nowhere else for the
/// level to come from — but it was silent. A reader dragging to +8 dB heard no
/// change and had no way to tell that from a control that was broken. On the
/// percentage scale this replaced the silent loss was 3.5 dB; with the +8 dB
/// top rung it is 8 dB, which is most of the slider.
///
/// `VolumeTrimRow` already disables itself outright when nothing is playing the
/// book. This is the adjacent case: something *is* playing it, and only half
/// the control can be honoured.
///
/// A plain type beside the view for the reason `AskSourceLabel` and
/// `ScreenAwake` are: `IssaSharedTests` cannot reach a SwiftUI `View`, and the
/// decision — which of the three states says what — is the part worth pinning.
enum VolumeTrimReach {
    /// Whether the louder half of the slider can actually be heard.
    ///
    /// - Parameter carriesGain: `AudioPlayer.tapCarriesGain`, or nil where
    ///   nothing is playing this book. Nil is "not yet known", not "no": before
    ///   the first item loads there is no tap to ask about, and treating that
    ///   as a refusal would caption every book for the moment before its tracks
    ///   resolve.
    static func canBeLouder(carriesGain: Bool?) -> Bool { carriesGain != false }

    /// The line under the slider, or nil when there is nothing to explain.
    static func caption(carriesGain: Bool?) -> String? {
        guard !canBeLouder(carriesGain: carriesGain) else { return nil }
        return "This book can only be made quieter. It is being streamed, and only a downloaded file can be played louder than it was recorded."
    }

    /// What VoiceOver reads as the slider's value.
    ///
    /// The caption above is hidden from VoiceOver and folded in here instead:
    /// a reader moving the slider is on the slider, and a caption below it is
    /// somewhere they have to go looking. Only where the level actually asks
    /// for more than can be delivered — at or below "as recorded" nothing is
    /// being lost and the warning would be noise.
    static func spoken(_ decibels: Int, carriesGain: Bool?) -> String {
        let level = VolumeTrim.spoken(decibels)
        guard !canBeLouder(carriesGain: carriesGain), VolumeTrim.clamped(decibels) > 0 else {
            return level
        }
        return "\(level), but this book can only be made quieter"
    }
}
#endif
