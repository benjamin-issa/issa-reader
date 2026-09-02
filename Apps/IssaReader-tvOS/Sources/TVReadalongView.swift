import IssaCore
import IssaUI
import SwiftUI

/// The TV readalong: one sentence at a time.
///
/// A paginated book page is unreadable across a room, so the TV shows the
/// narrated sentence large and centred with its neighbours dimmed for context —
/// the design's "one sentence at a time, or audio-only". Nothing here is
/// scrollable or focusable while narration runs; the remote drives playback,
/// not reading position.
/// Resolved through `AppModel`, exactly as `ReaderScreen` does on the other
/// platforms. Building a bare `ReaderModel` here left `enqueuePosition` nil, so
/// tvOS wrote positions straight to the network — outside the offline queue,
/// and outside `PositionGuard`, which is stated to be the one gate every writer
/// passes through. A dropped connection lost the position with nothing queued
/// to retry, and narration could overwrite a good reading place unchecked.
struct TVReadalongView: View {
    @Environment(AppModel.self) private var app
    let book: Book
    let session: Session

    var body: some View {
        TVReadalongContent(model: app.reader(for: book, session: session), book: book)
    }
}

private struct TVReadalongContent: View {
    let model: ReaderModel
    @Environment(AppModel.self) private var app
    @Environment(PlaybackSettings.self) private var settings
    let book: Book

    var body: some View {
        ZStack {
            model.style.theme.background.ignoresSafeArea()

            switch model.phase {
            case let .loading(message):
                VStack(spacing: 24) {
                    ProgressView()
                    Text(message).font(Typography.sans(28)).foregroundStyle(Palette.inkSecondary)
                }
            case let .downloading(received, total):
                VStack(spacing: 24) {
                    Text(model.book.title).font(Typography.serif(48, weight: .medium))
                    if total > 0 {
                        ProgressView(value: Double(received), total: Double(total))
                            .tint(Palette.tangerine)
                            .frame(width: 520)
                        Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                            .font(Typography.sans(24).monospacedDigit())
                            .foregroundStyle(Palette.inkSecondary)
                    } else {
                        ProgressView().frame(width: 520)
                    }
                }
            case let .failed(reason):
                VStack(spacing: 20) {
                    Text("Couldn't open this book").font(Typography.serif(48, weight: .medium))
                    Text(reason).font(Typography.sans(24)).foregroundStyle(Palette.inkSecondary)
                }
                .padding(80)
            case .ready:
                content
            }
        }
        .task {
            model.style = settings.readerStyle
            // Only a model that is not already open. The model is cached in
            // `AppModel.readers`, and `open()` rebuilds the narration
            // coordinator from scratch — so re-entering a playing book built a
            // second AVQueuePlayer while Now Playing still held, and still
            // played, the first. `.loading`/`.downloading` re-enter safely
            // (the transfer belongs to the background session), and `.failed`
            // retries, which is the only way back in with no retry button here.
            if case .ready = model.phase {} else {
                // Layout still needs a page size to resolve fragment ranges,
                // even though pages are never shown here.
                await model.open(pageSize: CGSize(width: 1400, height: 900))
            }
            // Not while it is already playing: `startNarration()` would seek
            // the running coordinator back to the reader position mid-sentence.
            if model.hasNarration, !model.isPlaying { await model.startNarration() }
        }
        .onDisappear {
            Task { await model.saveProgress() }
            // Released only if nothing is playing it, exactly as `ReaderView`
            // does on the other platforms — without this every book browsed on
            // the TV pinned its chapter layout and decoded plates for the rest
            // of the session.
            app.readerDidClose(model)
        }
        .onPlayPauseCommand { Task { await model.togglePlayback() } }
        .onChange(of: settings.readerStyle) { _, style in model.style = style }
    }

    private var content: some View {
        let context = model.narrationContext()
        return VStack(spacing: 44) {
            VStack(spacing: 12) {
                Text(book.title.uppercased())
                    .font(Typography.sans(22, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(Palette.tangerine)
                Text(model.chapterTitle)
                    .font(Typography.sans(26))
                    .foregroundStyle(Palette.inkTertiary)
            }

            if model.hasNarration {
                VStack(spacing: 28) {
                    contextLine(context.previous)
                    Text(context.current ?? "…")
                        .font(Typography.serif(54, weight: .regular))
                        .foregroundStyle(model.style.theme.text)
                        .multilineTextAlignment(.center)
                        .lineSpacing(14)
                        .frame(maxWidth: 1500)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 24)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(model.style.theme.highlight),
                        )
                        .animation(.easeOut(duration: 0.25), value: context.current)
                    contextLine(context.next)
                }
            } else {
                Text("This book has no narration on your server.")
                    .font(Typography.sans(30))
                    .foregroundStyle(Palette.inkSecondary)
            }

            Text(model.isPlaying ? "Playing — press play/pause on the remote" : "Paused")
                .font(Typography.sans(22))
                .foregroundStyle(Palette.inkQuaternary)
        }
        .padding(80)
    }

    /// Neighbouring sentences, dimmed so the eye stays on the spoken one.
    @ViewBuilder
    private func contextLine(_ text: String?) -> some View {
        Text(text ?? " ")
            .font(Typography.serif(32))
            .foregroundStyle(model.style.theme.text.opacity(0.32))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: 1400)
    }
}
