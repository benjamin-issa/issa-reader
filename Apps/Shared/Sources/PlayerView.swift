import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

/// The player, as the design lays it out: square audiobook art, title and
/// narrator, a scrubber, and transport whose skip buttons carry their own
/// interval so the amount is never a mystery.
public struct PlayerView: View {
    @Environment(PlaybackSettings.self) private var settings
    let book: Book
    let session: Session?
    let coordinator: ReadalongCoordinator?

    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var sleepTimer: SleepTimer?

    public init(book: Book, session: Session?, coordinator: ReadalongCoordinator?) {
        self.book = book
        self.session = session
        self.coordinator = coordinator
    }

    private var progress: Double {
        scrubbing ? scrubValue : (coordinator?.bookProgress ?? book.progress ?? 0)
    }

    private var total: TimeInterval {
        coordinator?.totalDuration ?? book.readaloud?.duration ?? book.audiobook?.duration ?? 0
    }

    public var body: some View {
        VStack(spacing: Metrics.spacing24) {
            // Square art on the player, portrait on the shelf — the design uses
            // the two covers Storyteller stores by context.
            CoverImage(book: book, session: session, aspect: 1)
                .frame(maxWidth: 320)
                .shadow(color: Palette.ink.opacity(0.18), radius: 24, y: 12)

            VStack(spacing: Metrics.spacing4) {
                Text(book.title)
                    .font(Typography.title)
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                Text(byline)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkTertiary)
            }

            scrubber
            transport

            HStack(spacing: Metrics.spacing24) {
                rateControl
                Spacer()
                sleepTimerControl
            }
            .padding(.horizontal, Metrics.spacing8)
        }
        .padding(Metrics.spacing24)
        .background(Palette.paper)
    }

    private var byline: String {
        var parts = [book.byline]
        let narrators = book.narrators.map(\.name).joined(separator: ", ")
        if !narrators.isEmpty { parts.append(narrators) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var scrubber: some View {
        VStack(spacing: Metrics.spacing4) {
            // tvOS has no Slider, and dragging a scrubber with a Siri Remote is
            // miserable anyway — there, seeking is the remote's job and this is
            // a read-only indicator.
            #if os(tvOS)
            ProgressBar(value: progress)
            #else
            Slider(
                value: Binding(get: { progress }, set: { scrubValue = $0 }),
                in: 0 ... 1,
                onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing {
                        Task { await coordinator?.seek(toBookProgress: scrubValue) }
                    }
                },
            )
            .tint(Palette.tangerine)
            .disabled(coordinator == nil)
            #endif

            HStack {
                Text(Self.timeText(total * progress))
                Spacer()
                Text("-" + Self.timeText(total * (1 - progress)))
            }
            .font(Typography.caption.monospacedDigit())
            .foregroundStyle(Palette.inkTertiary)
        }
    }

    private var transport: some View {
        HStack(spacing: Metrics.spacing32) {
            skipButton(
                seconds: settings.commandMap.skipBackwardInterval,
                symbol: "gobackward", action: .skipBackward,
            )
            Button {
                Task { await coordinator?.perform(.playPause, using: settings.commandMap) }
            } label: {
                Image(systemName: (coordinator?.player.isPlaying ?? false) ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 68, height: 68)
                    .background(Palette.tangerine, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(coordinator == nil)

            skipButton(
                seconds: settings.commandMap.skipForwardInterval,
                symbol: "goforward", action: .skipForward,
            )
        }
    }

    /// The interval is drawn inside the button, so "how far does this jump" is
    /// answered without opening settings.
    private func skipButton(seconds: TimeInterval, symbol: String, action: PlaybackAction) -> some View {
        Button {
            Task { await coordinator?.perform(action, using: settings.commandMap) }
        } label: {
            ZStack {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .regular))
                Text("\(Int(seconds))")
                    .font(Typography.sans(11, weight: .semibold))
                    .offset(y: 1)
            }
            .foregroundStyle(Palette.ink)
        }
        .buttonStyle(.plain)
        .disabled(coordinator == nil)
    }

    private var rateControl: some View {
        Menu {
            ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { rate in
                Button(Self.rateText(rate)) {
                    coordinator?.player.rate = Float(rate)
                    settings.playbackRate = rate
                }
            }
        } label: {
            Text(Self.rateText(Double(coordinator?.player.rate ?? Float(settings.playbackRate))))
                .font(Typography.subhead)
                .padding(.horizontal, Metrics.spacing12)
                .padding(.vertical, Metrics.spacing8)
                .background(Palette.surface, in: Capsule())
                .foregroundStyle(Palette.ink)
        }
        .disabled(coordinator == nil)
    }

    private var sleepTimerControl: some View {
        Menu {
            ForEach(SleepTimer.presets, id: \.self) { mode in
                Button(mode.title) { sleepTimer?.start(mode) }
            }
            if sleepTimer?.mode != SleepTimer.Mode.off {
                Divider()
                Button("Cancel timer", role: .destructive) { sleepTimer?.cancel() }
            }
        } label: {
            HStack(spacing: Metrics.spacing4) {
                Image(systemName: sleepTimer?.mode == SleepTimer.Mode.off ? "moon" : "moon.fill")
                    .font(.system(size: 16))
                if let text = sleepTimer?.remainingText {
                    Text(text).font(Typography.caption.monospacedDigit())
                }
            }
            .foregroundStyle(sleepTimer?.mode == SleepTimer.Mode.off ? Palette.inkTertiary : Palette.tangerine)
        }
        .disabled(coordinator == nil)
        .task {
            guard sleepTimer == nil, let coordinator else { return }
            sleepTimer = SleepTimer(
                onExpire: { coordinator.player.pause() },
                // Fade the last seconds rather than cutting off mid-word.
                fade: { level in coordinator.player.volume = level },
            )
        }
    }

    static func rateText(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.2g×", rate)
    }

    static func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
