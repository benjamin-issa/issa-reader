import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

/// The television's book screen.
///
/// Not a detail screen with a reader behind it: on an Apple TV the read-along
/// *is* the book, so this one screen carries the page, where the reader has got
/// to, and the controls to move through them.
///
/// It draws a **page**, laid out by the same TextKit 2 engine the phone and the
/// Mac use. What it replaced was a column of sentences, one per row, which read
/// as a teleprompter and truncated anything long. A page brings the paragraphs,
/// the chapter headings and the read-along block back, and it turns — which is
/// the only thing a remote can usefully do to a book.
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

    @FocusState private var focus: TVFocus?
    /// The chapter marks, built once when the book opens.
    ///
    /// Held rather than computed in `body`: building them walks the whole
    /// navigation — several hundred entries on a long book — and the answer
    /// changes only when the book does.
    @State private var ticks: [TVBookTimeline.Tick] = []

    /// The overscan-safe gutter, matching the shelf.
    private static let margin: CGFloat = Metrics.screenMargin
    /// The footer's cover, tall enough to recognise across a room and short
    /// enough to leave the transport its row.
    ///
    /// Raw points, like the bands in `TVPageMetrics` and for the same reason:
    /// the footer is 84 pt of the television's own 1080, and a `Metrics` token
    /// would double itself here and burst the band.
    private static let coverHeight: CGFloat = 56
    /// The transport capsules, sized to fit inside the footer band beside the
    /// cover and the progress line.
    private static let capsuleWidth: CGFloat = 76
    private static let capsuleHeight: CGFloat = 60

    var body: some View {
        GeometryReader { geometry in
            // The whole window, not the safe-area content box: the title-safe
            // margin below *is* the TV's overscan allowance, and measuring the
            // safe box would subtract it a second time.
            let frames = TVPageMetrics.frames(
                in: geometry.size, margin: Self.margin, fontSize: TVReaderStyle.fontSize,
            )

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
                    reading(frames)
                }
            }
            // Keyed on the page, so a chapter is laid out again only when the
            // size it must fit into actually changes.
            .task(id: frames.pageSize) {
                // Before `open`, so the first parse is already at ten-foot size
                // and the book does not visibly re-flow from 18 pt to 40.
                applyStyle()
                switch model.phase {
                case .loading, .downloading:
                    await model.open(pageSize: frames.pageSize)
                case .ready:
                    await model.resize(to: frames.pageSize)
                case .failed:
                    break
                }
                if let package = model.package {
                    // Off the main actor: placing a chapter mark reads the
                    // spine documents its anchor points into, which on a long
                    // novel is a megabyte of markup to inflate and scan. Both
                    // arguments are `Sendable`, and nothing on screen depends
                    // on the answer until it arrives.
                    let timeline = model.timeline
                    ticks = await Task.detached {
                        TVBookTimeline.ticks(for: package, timeline: timeline)
                    }.value
                }
                // The page is where the remote should be, and `defaultFocus`
                // alone cannot deliver it: the page does not exist yet while
                // the book is still opening, so there was nothing to focus.
                if case .ready = model.phase { focus = .page }
                if model.hasNarration, !model.isPlaying { await model.startNarration() }
            }
        }
        // Measure the window, not the safe-area content box.
        .ignoresSafeArea()
        // The tab bar draws over the top of the screen on tvOS and would sit
        // exactly where the running header is. Menu still pops the navigation
        // stack with it hidden.
        .toolbar(.hidden, for: .tabBar)
        .defaultFocus($focus, .page)
        .onDisappear {
            Task { await model.saveProgress() }
            Task { @MainActor in app.readerDidClose(model) }
        }
        .onPlayPauseCommand { Task { await model.playFromVisiblePage() } }
        // No `.onExitCommand` here, deliberately. Adding one and calling
        // `dismiss()` from it made a single Menu press pop twice — out of the
        // book and then out of the app to the tvOS home screen. The stack
        // already pops on Menu, and `onDisappear` above already writes the
        // position; the modifier had nothing to add and something to break.
        .onChange(of: settings.readerStyle) { _, _ in applyStyle() }
    }

    /// The reader's settings, re-cut for ten feet, and never written back.
    ///
    /// `publisherFamily` is carried across by hand because it belongs to the
    /// book rather than to the settings: assigning `settings.readerStyle`
    /// wholesale — which is what this screen used to do — dropped the face a
    /// book embeds every time anything else changed.
    private func applyStyle() {
        model.style = TVReaderStyle.derive(
            from: settings.readerStyle, publisherFamily: model.style.publisherFamily,
        )
    }

    private func centred(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: Metrics.spacing24) { content() }
            .padding(Self.margin)
    }

    // MARK: - Reading

    /// The four bands, each placed at the rectangle `TVPageMetrics` gave it.
    ///
    /// Absolute placement rather than a stack, because the page's height is the
    /// input to pagination: a stack that let the footer grow by a line would
    /// re-paginate the chapter under the reader, and a book that re-flows when
    /// the progress readout gets longer is a book that loses your place.
    private func reading(_ frames: TVPageMetrics.Frames) -> some View {
        ZStack {
            band(frames.header) { header }
            band(frames.page) {
                TVPageView(model: model, size: frames.page.size, focus: $focus)
            }
            band(frames.timeline) {
                TVBookTimelineView(
                    ticks: ticks,
                    progress: timelineProgress,
                    currentTick: TVBookTimeline.currentIndex(in: ticks, fraction: timelineProgress),
                    track: model.style.theme.text.opacity(0.15),
                    accent: model.style.theme.accent,
                    paper: model.style.theme.background,
                )
            }
            band(frames.footer) { footer }
        }
    }

    private func band(_ rect: CGRect, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    /// Book on the left, chapter on the right, the way a printed book runs its
    /// heads — so a reader glancing up knows both without either competing with
    /// the page.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing24) {
            Text(book.title)
                .lineLimit(1)
            Spacer(minLength: Metrics.spacing16)
            Text(chapterLabel)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
        }
        .font(Typography.sans(24, weight: .semibold))
        .textCase(.uppercase)
        .tracking(Metrics.overlineTracking)
        .foregroundStyle(model.style.theme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The chapter, or where in it the reader is.
    ///
    /// `chapterTitle` answers with the *book's* title when a book has no
    /// navigation entry covering this page, and a running head that says the
    /// same thing twice tells a reader nothing. The page number does.
    private var chapterLabel: String {
        let title = model.chapterTitle
        if !title.isEmpty, title != book.title { return title }
        guard model.pageCount > 0 else { return "" }
        return "Page \(model.pageIndex + 1) of \(model.pageCount)"
    }

    // MARK: - Where the reader is

    /// How far through the book, on the clock the chapter marks were built on.
    ///
    /// Audio time once narration has an anchor, byte-weighted spine progress
    /// before that and always for a book with no narration. Mixing the two on
    /// one strip would put the marker on the wrong side of a chapter mark: a
    /// book 40% read by audio is rarely 40% read by weight.
    private var timelineProgress: Double {
        if let coordinator = model.readalong, coordinator.activeEntry != nil {
            return coordinator.bookProgress
        }
        return model.bookProgress
    }

    /// What is left to listen to, when there is anything to listen to.
    private var remainingTime: TimeInterval? {
        guard let coordinator = model.readalong, coordinator.totalDuration > 0 else { return nil }
        return coordinator.totalDuration * (1 - (coordinator.bookProgress.asProgression ?? 0))
    }

    private var progressLine: String {
        let place = timelineProgress
        return TVBookTimeline.progressLine(
            chapter: TVBookTimeline.currentIndex(in: ticks, fraction: place).map { $0 + 1 },
            count: ticks.count,
            progress: place,
            remaining: remainingTime,
        )
    }

    /// What the remote does, said once, quietly.
    private var hintLine: String {
        model.hasNarration
            ? "◀ ▶ turn the page · Play/Pause on the remote · Menu goes back"
            : "◀ ▶ turn the page · Menu goes back"
    }

    private var footer: some View {
        HStack(spacing: Metrics.spacing16) {
            CoverImage(book: book, session: session)
                .frame(height: Self.coverHeight)
            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                Text(progressLine)
                    .font(Typography.sans(22).monospacedDigit())
                    .foregroundStyle(model.style.theme.textSecondary)
                Text(hintLine)
                    .font(Typography.sans(18))
                    .foregroundStyle(Palette.inkQuaternary)
            }
            .lineLimit(1)
            Spacer(minLength: Metrics.spacing16)
            if model.hasNarration {
                transport
            } else {
                // A plain ebook is still a readable book here — the page turns,
                // the timeline runs on the text — so this says what is missing
                // rather than refusing to open the book, which is what the
                // screen used to do.
                //
                // Focusable, and claiming `.transport`, even though there is
                // nothing on it to press. As a plain `Text` it claimed no focus
                // value at all, so on a plain ebook this screen had exactly one
                // focus target — and `TVPageView` assigned `.transport` on Down
                // regardless, to a value nothing answered to. Focus left the
                // page and landed nowhere; `onMoveCommand` is attached to the
                // page, so it stopped receiving anything at all; Left and Right
                // stopped turning pages; and Menu, which leaves the book, was
                // the only way out. `.defaultFocus` had already run by then and
                // does not fire again.
                //
                // `TVFocusMoves` now refuses that move, so this row is the
                // second half rather than the first: the focus engine moves
                // focus on a swipe on its own, and a swipe with nowhere to go is
                // how the reader got stranded. The old screen mounted the
                // transport row unconditionally and merely disabled it, which is
                // why it never had this fault.
                Text("No narration for this book")
                    .font(Typography.sans(22))
                    .foregroundStyle(Palette.inkTertiary)
                    .focusable()
                    .focused($focus, equals: .transport)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Moving through the book

    /// The transport, dimmed while the page has the remote.
    ///
    /// A focus section, so left and right inside the row move between buttons
    /// rather than escaping it, and up returns to the page.
    private var transport: some View {
        HStack(spacing: Metrics.spacing12) {
            transportButton(
                "gobackward", label: "Back \(Int(settings.commandMap.skipBackwardInterval)) seconds",
            ) { await model.readalong?.perform(.skipBackward, using: settings.commandMap) }

            transportButton(model.isPlaying ? "pause.fill" : "play.fill",
                            label: model.isPlaying ? "Pause" : "Play") {
                await model.playFromVisiblePage()
            }
            .focused($focus, equals: .transport)

            transportButton(
                "goforward", label: "Forward \(Int(settings.commandMap.skipForwardInterval)) seconds",
            ) { await model.readalong?.perform(.skipForward, using: settings.commandMap) }

            transportButton("chevron.left.2", label: "Previous chapter") {
                await model.readalong?.perform(.previousChapter, using: settings.commandMap)
            }
            transportButton("chevron.right.2", label: "Next chapter") {
                await model.readalong?.perform(.nextChapter, using: settings.commandMap)
            }
        }
        .focusSection()
        // Present but quiet while the reader is on the page, which is where
        // they should be: the controls are for when they are wanted.
        .opacity(focus == .page ? 0.7 : 1)
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
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(model.style.theme.text)
                .frame(width: Self.capsuleWidth, height: Self.capsuleHeight)
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
