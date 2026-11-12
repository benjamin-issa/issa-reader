import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

/// The television's player for a book with an audiobook and no read-along.
///
/// The read-along screen has nothing to show for such a title: no page to
/// draw, and no narration to follow. This is the player the phone puts in a
/// sheet, drawn for ten feet and driven by the same code — `AppModel`'s
/// listening, its `AudiobookCoordinator`, `NowPlayingController` for the
/// system's transport, and the position writer that already runs while a book
/// plays. It adds no networking of its own.
///
/// Leaving the screen leaves the audio playing, as closing the player does on
/// the phone. Nothing here holds the screen saver off: that hold belongs to a
/// page being read.
///
/// **Play/Pause on the remote is not handled here.** `NowPlayingController`
/// registers the system's play, pause and toggle commands for the book that is
/// playing, and the remote's button reaches them. A second handler on this
/// view (`onPlayPauseCommand`) would be a second owner of the same press, and
/// the two toggling in turn is a press that does nothing. The button in this
/// view's transport is a click on the screen, which no command sees.
///
/// There is no `onExitCommand` either, for the reason `TVReadalongView` gives:
/// the navigation stack already pops on Menu, and a second handler popped
/// twice.
struct TVAudiobookView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlaybackSettings.self) private var settings
    @Environment(NowPlayingController.self) private var nowPlaying
    let book: Book
    let session: Session

    private enum Focus: Hashable {
        case playPause
        case chapter(Int)
    }

    @FocusState private var focus: Focus?

    private static let margin: CGFloat = Metrics.screenMargin
    private static let capsuleWidth: CGFloat = 96
    private static let capsuleHeight: CGFloat = 76

    /// The coordinator, only while it is this book's: another book's audio
    /// still playing when this screen opens is not drawn as this one's.
    private var coordinator: AudiobookCoordinator? {
        app.listeningBook?.uuid == book.uuid ? app.listening : nil
    }

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            HStack(alignment: .top, spacing: Metrics.spacing48) {
                player
                if let coordinator, coordinator.chapters.count > 1 {
                    chapterList(coordinator)
                        .frame(maxWidth: 700)
                }
            }
            .padding(Self.margin)
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .tabBar)
        .defaultFocus($focus, .playPause)
        .task {
            // Not started again for the book already playing: that is a
            // person coming back to the screen, and starting would resume a
            // pause they chose.
            guard app.listeningBook?.uuid != book.uuid else { return }
            await app.startListening(to: book, nowPlaying: nowPlaying, settings: settings)
            if coordinator != nil { focus = .playPause }
        }
    }

    // MARK: - The player

    private var player: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            HStack(alignment: .top, spacing: Metrics.spacing32) {
                CoverImage(book: book, session: session)
                    .frame(height: 360)
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    Text(book.title)
                        .font(Typography.serif(54, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(3)
                    if !book.byline.isEmpty {
                        Text(book.byline)
                            .font(Typography.sans(28))
                            .foregroundStyle(Palette.inkSecondary)
                            .lineLimit(2)
                    }
                    if let coordinator, !coordinator.chapterTitle.isEmpty {
                        Text(coordinator.chapterTitle)
                            .font(Typography.sans(26, weight: .semibold))
                            .foregroundStyle(Palette.tangerine)
                            .lineLimit(2)
                    }
                }
            }
            if let coordinator {
                progress(coordinator)
                transport(coordinator)
            } else if let error = app.listeningError {
                Text(error)
                    .font(Typography.sans(26))
                    .foregroundStyle(Palette.alert)
            } else {
                HStack(spacing: Metrics.spacing16) {
                    ProgressView()
                    Text("Starting…")
                        .font(Typography.sans(26))
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progress(_ coordinator: AudiobookCoordinator) -> some View {
        let total = coordinator.totalDuration
        let elapsed = min(max(coordinator.bookTime, 0), total.isFinite ? total : 0)
        return VStack(spacing: Metrics.spacing8) {
            ProgressView(value: coordinator.progress)
                .tint(Palette.tangerine)
            HStack {
                Text(Self.timeText(elapsed))
                Spacer()
                Text("-" + Self.timeText(max(total - elapsed, 0)))
            }
            .font(Typography.sans(24).monospacedDigit())
            .foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: 1000)
    }

    private func transport(_ coordinator: AudiobookCoordinator) -> some View {
        HStack(spacing: Metrics.spacing12) {
            transportButton(
                "chevron.left.2", label: "Previous chapter",
            ) { await coordinator.perform(.previousChapter, using: settings.commandMap) }
            transportButton(
                "gobackward", label: "Back \(Int(settings.commandMap.skipBackwardInterval)) seconds",
            ) { await coordinator.perform(.skipBackward, using: settings.commandMap) }
            transportButton(
                coordinator.player.isPlaying ? "pause.fill" : "play.fill",
                label: coordinator.player.isPlaying ? "Pause" : "Play",
            ) { await coordinator.perform(.playPause, using: settings.commandMap) }
            .focused($focus, equals: .playPause)
            transportButton(
                "goforward", label: "Forward \(Int(settings.commandMap.skipForwardInterval)) seconds",
            ) { await coordinator.perform(.skipForward, using: settings.commandMap) }
            transportButton(
                "chevron.right.2", label: "Next chapter",
            ) { await coordinator.perform(.nextChapter, using: settings.commandMap) }
            speedMenu(coordinator)
        }
        .focusSection()
    }

    /// The look of `TVReadalongView`'s transport: a glyph in a capsule, with
    /// explicit colours because the app's tint would otherwise paint the glyph
    /// the same orange as the fill.
    private func transportButton(
        _ symbol: String, label: String, action: @escaping () async -> Void,
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: Self.capsuleWidth, height: Self.capsuleHeight)
                .background(Palette.ink.opacity(0.10), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func speedMenu(_ coordinator: AudiobookCoordinator) -> some View {
        Menu {
            ForEach(PlaybackRate.ladder, id: \.self) { rate in
                Button(Self.rateText(rate)) {
                    coordinator.player.rate = Float(rate)
                    settings.playbackRate = rate
                }
            }
        } label: {
            Text(Self.rateText(Double(coordinator.player.rate)))
                .font(Typography.sans(28, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(minWidth: Self.capsuleWidth, minHeight: Self.capsuleHeight)
                .padding(.horizontal, Metrics.spacing12)
                .background(Palette.ink.opacity(0.10), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed")
    }

    // MARK: - Chapters

    /// Each row plays its chapter, and the one playing is marked.
    private func chapterList(_ coordinator: AudiobookCoordinator) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing8) {
                ForEach(Array(coordinator.chapters.enumerated()), id: \.offset) { index, chapter in
                    let current = index == coordinator.chapterIndex
                    Button {
                        Task { await coordinator.play(chapter: index) }
                    } label: {
                        HStack(spacing: Metrics.spacing12) {
                            Image(systemName: current ? "speaker.wave.2.fill" : "circle")
                                .opacity(current ? 1 : 0)
                                .frame(width: 36)
                            Text(chapter.title)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .font(Typography.sans(26, weight: current ? .semibold : .regular))
                        .foregroundStyle(current ? Palette.tangerine : Palette.ink)
                        .padding(.vertical, Metrics.spacing8)
                        .padding(.horizontal, Metrics.spacing16)
                    }
                    .buttonStyle(.plain)
                    .focused($focus, equals: .chapter(index))
                    .accessibilityLabel(current ? "\(chapter.title), playing" : chapter.title)
                }
            }
            .padding(.vertical, Metrics.spacing16)
        }
        .focusSection()
    }

    // MARK: - Text

    static func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0, seconds < 1_000_000 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func rateText(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate)
    }
}
