import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

/// The Playing tab: the full player for whatever is running.
///
/// The mini bar expands into this rather than into a sheet. One expanded player
/// in the app means one place the scrubber, the rate and the sleep timer can be
/// in, which is a smaller thing to keep honest than two.
///
/// With nothing playing it offers the book most recently read rather than an
/// empty screen, because "start the thing I was in the middle of" is the only
/// reason to open this tab when it is quiet.
public struct NowPlayingTab: View {
    @Environment(AppModel.self) private var app
    @Environment(NowPlayingController.self) private var nowPlaying
    @Environment(PlaybackSettings.self) private var settings

    public init() {}

    public var body: some View {
        Group {
            if let book = app.playbackBook {
                PlayerView(
                    book: book, session: app.session, coordinator: app.playback,
                    chapterTitle: app.playbackChapterTitle,
                )
            } else if let book = app.continueBook, book.canBeListenedTo {
                idle(book)
            } else {
                ContentUnavailableView(
                    "Nothing playing",
                    systemImage: "headphones",
                    description: Text("Start a book from your library and it will appear here."),
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper)
    }

    /// The last book, ready to resume — the player's own layout, greyed of its
    /// transport, would be a lie about what is loaded.
    private func idle(_ book: Book) -> some View {
        VStack(spacing: Metrics.spacing24) {
            CoverImage(book: book, session: app.session, aspect: 1, shape: .square)
                .frame(maxWidth: 240)
                .shadow(color: Palette.ink.opacity(0.18), radius: 24, y: 12)

            VStack(spacing: Metrics.spacing4) {
                Text(book.title)
                    .font(Typography.title)
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                Text(book.byline)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkTertiary)
            }

            Button {
                Task { await app.startListening(to: book, nowPlaying: nowPlaying, settings: settings) }
            } label: {
                Label("Listen", systemImage: "headphones")
                    .font(Typography.callout.weight(.semibold))
                    .padding(.horizontal, Metrics.spacing24)
                    .padding(.vertical, Metrics.spacing12)
                    .background(Palette.tangerine, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(Metrics.spacing32)
    }
}

private extension Book {
    /// `servableFormats`, not `availableFormats`: the latter is a bare nil check
    /// and over-promises a book the server cannot actually stream.
    var canBeListenedTo: Bool {
        servableFormats.contains(.audiobook) || servableFormats.contains(.readaloud)
    }
}
