import IssaCore
import IssaPlayback
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
    @Environment(PlaybackSettings.self) private var settings
    /// Whether this panel is the key window. The ⌘⌥↑/↓ below and the same pair
    /// in every reader window all listen to one notification, and the guard is
    /// what makes the shortcut mean "the book in front of me": only one window
    /// is ever key, so exactly one of the listeners answers.
    @Environment(\.controlActiveState) private var controlActiveState

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
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.volumeUp.notification)) { _ in
            nudge(by: VolumeTrim.step)
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.volumeDown.notification)) { _ in
            nudge(by: -VolumeTrim.step)
        }
    }

    /// Trims whatever this panel is showing. Nothing playing is nothing to
    /// trim: there is no book for the level to belong to.
    private func nudge(by delta: Int) {
        guard controlActiveState == .key, let book = app.playbackBook else { return }
        VolumeTrimControl.nudge(
            by: delta, for: book, coordinator: app.playback, settings: settings)
    }
}
