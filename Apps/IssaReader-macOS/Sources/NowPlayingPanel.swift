import IssaCore
import IssaUI
import SwiftUI

/// The Mac's Now Playing surface.
///
/// A window rather than a sheet, because several books can be open at once and
/// a sheet would belong to whichever one happened to summon it. It hosts the
/// same `PlayerView` the phone's sheet does — square art, title and chapter,
/// scrubber, transport with the intervals from Controls, rate and sleep timer —
/// so there is one player in this app, not a second one written for the Mac.
///
/// It owns no playback state. Closing it stops nothing.
struct NowPlayingPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let book = app.playbackBook, let coordinator = app.playback {
                PlayerView(
                    book: book, session: app.session,
                    coordinator: coordinator, chapterTitle: app.playbackChapterTitle,
                )
            } else {
                // Not an error. Opening the panel before starting anything is a
                // reasonable thing to do, and a blank window would be worse
                // than a sentence saying where playback comes from.
                VStack(spacing: Metrics.spacing12) {
                    Image(systemName: "headphones")
                        .font(.system(size: 44))
                        .foregroundStyle(Palette.inkQuaternary)
                    Text("Nothing playing")
                        .font(Typography.title)
                        .foregroundStyle(Palette.ink)
                    Text("Press Listen on a book, or play the narration in a reader window.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.inkTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(Metrics.spacing32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.paper)
    }
}
