import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

/// The television's book screen.
///
/// Not a detail screen with a reader behind it: on an Apple TV the read-along
/// *is* the book, so this one screen carries the artwork, where the reader has
/// got to, the words being spoken, and the controls to move through them.
///
/// The cover and the metadata hold a fixed rail on the left while the sentences
/// roll past on the right, which is what keeps the spoken line in the same place
/// on screen rather than making the eye chase it up and down a centred column.
struct TVReadalongView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlaybackSettings.self) private var settings
    @State private var model: ReaderModel?
    let book: Book
    let session: Session

    var body: some View {
        ZStack {
            settings.readerStyle.theme.background.ignoresSafeArea()
            if let model {
                TVReadalongContent(model: model, book: book, session: session)
            }
        }
        .onAppear {
            if model == nil { model = app.reader(for: book, session: session) }
            // The only callers of this were in `ReaderView`, which tvOS does
            // not render — so `isReaderVisible` stayed false, the audio observer
            // kept the 1.0s idle interval instead of 0.20s, and the sentence
            // highlight (the entire point of this screen) stepped once a second
            // while any sentence shorter than the tick was never marked at all.
            model?.setReaderVisible(true)
        }
        .onDisappear { model?.setReaderVisible(false) }
    }
}

private struct TVReadalongContent: View {
    let model: ReaderModel
    @Environment(AppModel.self) private var app
    @Environment(PlaybackSettings.self) private var settings
    let book: Book
    let session: Session

    /// The overscan-safe gutter, matching the shelf.
    private static let margin: CGFloat = Metrics.screenMargin

    var body: some View {
        ZStack {
            model.style.theme.background.ignoresSafeArea()

            switch model.phase {
            case let .loading(message):
                centred {
                    ProgressView()
                    Text(message)
                        .font(Typography.sans(28))
                        .foregroundStyle(Palette.inkSecondary)
                }
            case let .downloading(received, total):
                downloading(received: received, total: total)
            case let .failed(reason):
                centred {
                    Text("Couldn't open this book")
                        .font(Typography.serif(48, weight: .medium))
                        .foregroundStyle(model.style.theme.text)
                    Text(reason)
                        .font(Typography.sans(24))
                        .foregroundStyle(Palette.inkSecondary)
                        .multilineTextAlignment(.center)
                    menuHint
                }
            case .ready:
                content
            }
        }
        .task {
            model.style = settings.readerStyle
            if case .ready = model.phase {} else {
                await model.open(pageSize: CGSize(width: 1400, height: 900))
            }
            if model.hasNarration, !model.isPlaying { await model.startNarration() }
        }
        .onDisappear {
            Task { await model.saveProgress() }
            Task { @MainActor in app.readerDidClose(model) }
        }
        .onPlayPauseCommand { Task { await model.togglePlayback() } }
        // No `.onExitCommand` here, deliberately. Adding one and calling
        // `dismiss()` from it made a single Menu press pop twice — out of the
        // book and then out of the app to the tvOS home screen. The stack
        // already pops on Menu, and `onDisappear` above already writes the
        // position; the modifier had nothing to add and something to break.
        .onChange(of: settings.readerStyle) { _, style in model.style = style }
    }

    private func centred(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: Metrics.spacing24) { content() }
            .padding(Self.margin)
    }

    // MARK: - Reading

    private var content: some View {
        HStack(alignment: .top, spacing: Metrics.spacing48) {
            rail
            VStack(alignment: .leading, spacing: Metrics.spacing32) {
                if model.hasNarration {
                    sentences
                } else {
                    Text("This book has no narration on your server.")
                        .font(Typography.sans(30))
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                VStack(spacing: Metrics.spacing12) {
                    transport
                    menuHint
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(Self.margin)
    }

    /// Fixed on the left: what is being read, and how far in.
    private var rail: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            CoverImage(book: book, session: session)
                .frame(width: 300)
            Text(book.title)
                .font(Typography.sans(26, weight: .semibold))
                .foregroundStyle(model.style.theme.text)
                .lineLimit(3)
            Text(book.byline)
                .font(Typography.sans(22))
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(2)
            Text(model.chapterTitle)
                .font(Typography.sans(22))
                .foregroundStyle(Palette.tangerine)
                .lineLimit(2)

            ProgressBar(value: progress)
                .padding(.top, Metrics.spacing8)
            Text(progressLine)
                .font(Typography.sans(20).monospacedDigit())
                .foregroundStyle(Palette.inkTertiary)
        }
        .frame(width: 300, alignment: .leading)
    }

    /// The whole-book fraction the phone shows on its own book screen, so the
    /// two devices agree about where the reader is.
    private var progress: Double { model.bookProgress }

    private var progressLine: String {
        var parts = ["\(ReadingProgress.percent(progress))%"]
        if let coordinator = model.readalong, coordinator.totalDuration > 0 {
            let remaining = coordinator.totalDuration * (1 - (coordinator.bookProgress.asProgression ?? 0))
            parts.append("\(Self.durationText(remaining)) left")
        }
        return parts.joined(separator: " · ")
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// Several sentences either side of the spoken one, which stays put while
    /// the rest roll past it.
    @ViewBuilder
    private var sentences: some View {
        let lines = model.narrationWindow(before: 3, after: 3)
        if lines.isEmpty {
            // Extracting the audio and finding the first fragment takes a
            // moment on a cold open, and an empty column reads as a broken
            // screen rather than as a pause.
            VStack(spacing: Metrics.spacing16) {
                ProgressView()
                Text(model.isPlaying ? "Finding your place…" : "Press play to start reading along.")
                    .font(Typography.sans(28))
                    .foregroundStyle(Palette.inkSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            window(lines)
        }
    }

    private func window(_ lines: [ReaderModel.NarratedLine]) -> some View {
        let currentIndex = lines.firstIndex(where: \.isCurrent) ?? 0
        return VStack(alignment: .leading, spacing: Metrics.spacing24) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { offset, line in
                Text(line.text)
                    .font(line.isCurrent
                        ? Typography.serif(48, weight: .regular)
                        : Typography.serif(32))
                    .foregroundStyle(model.style.theme.text)
                    // Fading with distance rather than one opacity for every
                    // neighbour: at three lines a side, a single dimmed value
                    // makes the furthest sentence as loud as the nearest.
                    .opacity(line.isCurrent ? 1 : max(0.18, 0.55 - 0.14 * Double(abs(offset - currentIndex) - 1)))
                    .padding(.horizontal, line.isCurrent ? Metrics.spacing24 : 0)
                    .padding(.vertical, line.isCurrent ? Metrics.spacing12 : 0)
                    .background {
                        if line.isCurrent {
                            RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous)
                                .fill(model.style.theme.highlight)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.25), value: lines.first?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Moving through the book

    /// Focusable controls, because until now the only thing this screen answered
    /// was play/pause and there was nothing on screen to say so.
    private var transport: some View {
        HStack(spacing: Metrics.spacing24) {
            transportButton(
                "gobackward", label: "Back \(Int(settings.commandMap.skipBackwardInterval)) seconds",
            ) { await model.readalong?.perform(.skipBackward, using: settings.commandMap) }

            transportButton(model.isPlaying ? "pause.fill" : "play.fill",
                            label: model.isPlaying ? "Pause" : "Play") {
                await model.togglePlayback()
            }

            transportButton(
                "goforward", label: "Forward \(Int(settings.commandMap.skipForwardInterval)) seconds",
            ) { await model.readalong?.perform(.skipForward, using: settings.commandMap) }

            Spacer().frame(width: Metrics.spacing32)

            transportButton("chevron.left.2", label: "Previous chapter") {
                await model.readalong?.perform(.previousChapter, using: settings.commandMap)
            }
            transportButton("chevron.right.2", label: "Next chapter") {
                await model.readalong?.perform(.nextChapter, using: settings.commandMap)
            }
        }
        .disabled(!model.hasNarration)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Explicit colours and an explicit ground.
    ///
    /// The app sets `.tint(Palette.tangerine)`, and a default tvOS button fills
    /// itself with the tint — so a tangerine glyph on a tangerine capsule is an
    /// orange blob with nothing legible on it. `TVSignInView` learned this the
    /// same way. `.plain` keeps the system's focus lift, which is wanted here:
    /// a glyph in a capsule has no text to clip.
    private func transportButton(
        _ symbol: String, label: String, action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(model.style.theme.text)
                .frame(width: 84, height: 66)
                .background(
                    model.style.theme.text.opacity(0.10),
                    in: Capsule(style: .continuous),
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The remote's Menu button is the only way back, and nothing said so.
    private var menuHint: some View {
        Text("Press Menu to go back.")
            .font(Typography.sans(20))
            .foregroundStyle(Palette.inkQuaternary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Downloading

    private func downloading(received: Int64, total: Int64) -> some View {
        VStack(spacing: Metrics.spacing24) {
            CoverImage(book: book, session: session)
                .frame(width: 220)
            Text(model.book.title)
                .font(Typography.serif(48, weight: .medium))
                // Explicit, and the reason this screen looked blank: this was
                // the one Text in the app that set no colour, so it took
                // `.primary` — which resolves against the *system* appearance —
                // over a reader ground that is a fixed near-white whatever the
                // system is doing. Under a dark appearance that is white on
                // white.
                .foregroundStyle(model.style.theme.text)
                .multilineTextAlignment(.center)

            if total > 0 {
                ProgressView(value: Double(received), total: Double(total))
                    .tint(Palette.tangerine)
                    // A 520-point bar on a 1920-point screen is a pencil line.
                    .frame(width: 900)
                Text("\(ByteCountText.text(received)) of \(ByteCountText.text(total))")
                    .font(Typography.sans(24).monospacedDigit())
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                ProgressView().frame(width: 900)
                Text(received > 0 ? ByteCountText.text(received) : "Starting…")
                    .font(Typography.sans(24).monospacedDigit())
                    .foregroundStyle(Palette.inkSecondary)
            }

            Button("Cancel download") { model.cancelDownload() }
                .font(Typography.sans(26))
                .padding(.top, Metrics.spacing16)
            menuHint
        }
        .padding(Self.margin)
    }
}
