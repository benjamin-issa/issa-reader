import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

/// The bar that says something is playing, from anywhere in the app.
///
/// Without it, starting a book and navigating away leaves audio coming out of
/// the phone with nothing on screen to stop it — the listener's only recourse
/// being the lock screen. It sits above the tab bar, shows real progress, and
/// opens the Playing tab.
///
/// Driven by `PlaybackDriving` rather than by the audiobook coordinator, so it
/// covers narration too. It did not before, which meant a read-along left
/// running behind the library had no in-app surface at all: no bar, no
/// transport, and no way to tell it was still going.
public struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    @Environment(NowPlayingController.self) private var nowPlaying
    @Environment(PlaybackSettings.self) private var settings

    /// Shows the full player. A tab rather than a sheet, so there is one
    /// expanded player in the app and not two that can disagree.
    private let onExpand: () -> Void

    public init(onExpand: @escaping () -> Void = {}) {
        self.onExpand = onExpand
    }

    public var body: some View {
        if let book = app.playbackBook, let coordinator = app.playback {
            content(book: book, coordinator: coordinator)
        }
    }

    private func content(book: Book, coordinator: any PlaybackDriving) -> some View {
        VStack(spacing: 0) {
            // A hairline of progress along the top edge: enough to see the book
            // moving without spending height the tab bar needs.
            GeometryReader { proxy in
                Rectangle()
                    .fill(Palette.tangerine)
                    .frame(width: proxy.size.width * fraction(of: coordinator))
            }
            .frame(height: 2)
            .background(Palette.border)

            HStack(spacing: Metrics.spacing12) {
                CoverImage(book: book, session: app.session, aspect: 1, shape: .square)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall))

                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    // Only when the book actually names it. The coordinator's
                    // own answer for a read-along is the text document's
                    // archive path, which was printed here as though it were a
                    // chapter.
                    if let chapter = app.playbackChapterTitle {
                        Text(chapter)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)

                skip(.skipBackward, symbol: "gobackward", label: "Skip back", on: coordinator)

                Button {
                    coordinator.player.togglePlayPause()
                    nowPlaying.publish()
                } label: {
                    // Tangerine, as in the full player. The same control was ink
                    // here and tangerine there, on the same tab.
                    Image(systemName: coordinator.player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.tangerine)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(coordinator.player.isPlaying ? "Pause" : "Play")

                skip(.skipForward, symbol: "goforward", label: "Skip forward", on: coordinator)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Metrics.spacing12)
            .padding(.vertical, Metrics.spacing8)
        }
        // Palette.surface, not .regularMaterial: system grey sat against warm
        // paper and was the only surface in the app not made from the palette.
        .background(Palette.surface)
        .overlay(alignment: .top) { Palette.border.frame(height: 0.5) }
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing: \(book.title)")
    }

    /// The same scope the player and the Lock Screen are using, so the hairline
    /// agrees with the bar it is a miniature of.
    private func fraction(of coordinator: any PlaybackDriving) -> Double {
        PlaybackProgress(
            scope: settings.progressScope,
            bookProgress: coordinator.bookProgress,
            totalDuration: coordinator.totalDuration,
            chapterSpan: coordinator.chapterSpan,
        ).fraction
    }

    /// Both directions, because one of them is the button a listener reaches for
    /// most and the other is the one that gets them past something.
    private func skip(
        _ action: PlaybackAction, symbol: String, label: String,
        on coordinator: any PlaybackDriving,
    ) -> some View {
        Button {
            Task {
                await coordinator.perform(action, using: settings.commandMap)
                nowPlaying.publish()
            }
        } label: {
            Image(systemName: symbol).font(.system(size: 18))
        }
        .accessibilityLabel(label)
    }
}
