import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

/// The bar that says something is playing, from anywhere in the app.
///
/// Without it, starting an audiobook and navigating away leaves audio coming
/// out of the phone with nothing on screen to stop it — the listener's only
/// recourse being the lock screen. It sits above the tab bar, shows real
/// progress, and opens the full player.
public struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    @Environment(NowPlayingController.self) private var nowPlaying
    @Environment(PlaybackSettings.self) private var settings
    @State private var showsPlayer = false

    public init() {}

    public var body: some View {
        if let book = app.listeningBook, let coordinator = app.listening {
            content(book: book, coordinator: coordinator)
                .sheet(isPresented: $showsPlayer) {
                    NavigationStack {
                        PlayerView(book: book, session: app.session, coordinator: coordinator)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showsPlayer = false }
                                }
                            }
                    }
                    .presentationDetents([.large])
                }
        }
    }

    private func content(book: Book, coordinator: AudiobookCoordinator) -> some View {
        VStack(spacing: 0) {
            // A hairline of progress along the top edge: enough to see the book
            // moving without spending height the tab bar needs.
            GeometryReader { proxy in
                Rectangle()
                    .fill(Palette.tangerine)
                    .frame(width: proxy.size.width * coordinator.bookProgress)
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
                    Text(coordinator.chapterTitle)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)

                Button {
                    Task {
                        await coordinator.perform(.skipBackward, using: settings.commandMap)
                        nowPlaying.publish()
                    }
                } label: {
                    Image(systemName: "gobackward").font(.system(size: 18))
                }
                .accessibilityLabel("Skip back")

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
        .onTapGesture { showsPlayer = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing: \(book.title)")
    }
}
