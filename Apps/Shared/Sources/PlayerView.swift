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
    let coordinator: (any PlaybackDriving)?
    /// The chapter's real name, where the caller has one.
    ///
    /// A read-along coordinator only knows which text document it is in, so
    /// left to itself this line is an archive path or nothing at all. The
    /// reader has the book's table of contents.
    let chapterTitle: String?

    @Environment(NowPlayingController.self) private var nowPlaying
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    public init(
        book: Book, session: Session?, coordinator: (any PlaybackDriving)?,
        chapterTitle: String? = nil,
    ) {
        self.book = book
        self.session = session
        self.coordinator = coordinator
        self.chapterTitle = chapterTitle
    }

    /// What the bar stands for, and what a drag on it means. One value, so the
    /// bar and its two times can never disagree.
    private var readout: PlaybackProgress {
        PlaybackProgress(
            scope: settings.progressScope,
            bookProgress: coordinator?.bookProgress ?? book.progress ?? 0,
            totalDuration: coordinator?.totalDuration ?? book.narrationDuration ?? 0,
            chapterSpan: coordinator?.chapterSpan,
        )
    }

    private var progress: Double {
        scrubbing ? scrubValue : readout.fraction
    }

    /// Shown under the title while a chapter is actually playing: an audiobook
    /// has real chapter names and it is the one place they belong.
    private var nowPlayingChapter: String? {
        if let chapterTitle, ChapterNaming.isDisplayable(chapterTitle) { return chapterTitle }
        return coordinator?.displayChapterTitle
    }

    /// The length of whatever the bar is showing — the chapter, or the book.
    private var total: TimeInterval { readout.spanDuration }

    public var body: some View {
        VStack(spacing: Metrics.spacing24) {
            // Square art on the player, portrait on the shelf — the design uses
            // the two covers Storyteller stores by context.
            CoverImage(book: book, session: session, aspect: 1, shape: .square)
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
                if let nowPlayingChapter {
                    Text(nowPlayingChapter)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkQuaternary)
                        .padding(.top, 2)
                }
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
        // Filled, then painted. A self-sizing stack takes only its intrinsic
        // height, so inside a sheet it sat centred and `Palette.paper` covered
        // just that band — leaving the sheet's own grey backdrop showing above
        // and below it. The Playing tab looked right only because it added
        // these two lines itself at the call site.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        // Through the bar's own inverse, so a drag lands where
                        // the bar drew it — which for a chapter-scoped bar is
                        // not the same as the raw fraction.
                        let target = readout.bookProgress(forFraction: scrubValue)
                        Task { await coordinator?.seek(toBookProgress: target) }
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

            bookReadout
        }
    }

    /// How much of the *book* is left, under a bar that is usually a chapter.
    ///
    /// The scope setting exists because a five-hour bar makes a chapter a
    /// sliver you cannot aim at — but it left the player with nothing anywhere
    /// saying how far through the book the listener is. One quiet line answers
    /// that without giving the bar back.
    @ViewBuilder
    private var bookReadout: some View {
        // A manifest that has not loaded would otherwise read
        // "0m left in book · 0%", which is worse than saying nothing.
        if bookLine.bookDuration > 0 {
            Text(bookReadoutText)
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(bookReadoutSpoken)
        }
    }

    /// At book scope the right-hand time above already *is* the book's
    /// remaining time. Printing it again in a second format invites the reader
    /// to hunt for a difference between two renderings of one number; the
    /// percent is the only part that is new information there.
    private var bookReadoutText: String {
        let percent = "\(bookLine.bookPercentComplete)%"
        guard settings.progressScope != .book else { return percent }
        return "\(Self.durationText(bookLine.bookRemaining)) left in book · \(percent)"
    }

    private var bookReadoutSpoken: String {
        let percent = "\(bookLine.bookPercentComplete) percent complete"
        guard settings.progressScope != .book else { return percent }
        return "\(Self.spokenDuration(bookLine.bookRemaining)) left in the book, \(percent)"
    }

    /// The book numbers, following a drag in progress.
    ///
    /// While `scrubbing`, the two times above are drawn from `scrubValue` and
    /// move with the thumb. A line read straight off `readout` would sit still
    /// through the drag and jump when it ended — three readouts of one position
    /// disagreeing, which is the thing `PlaybackProgress` exists to prevent.
    /// Built through the bar's own inverse, so the dragged fraction becomes a
    /// book position the same way a released drag does.
    private var bookLine: PlaybackProgress {
        guard scrubbing else { return readout }
        return PlaybackProgress(
            scope: .book,
            bookProgress: readout.bookProgress(forFraction: scrubValue),
            totalDuration: readout.bookDuration,
            chapterSpan: nil,
        )
    }

    private var transport: some View {
        HStack(spacing: Metrics.spacing32) {
            skipButton(
                seconds: settings.commandMap.skipBackwardInterval,
                symbol: "gobackward", action: .skipBackward,
            )
            Button {
                Task {
                    await coordinator?.perform(.playPause, using: settings.commandMap)
                    // The lock screen otherwise keeps the old rate until the
                    // five-second poll, extrapolating a clock the audio has
                    // stopped following. The mini player already does this.
                    nowPlaying.publish()
                }
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
            ForEach(PlaybackRate.ladder, id: \.self) { rate in
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

    /// The timer belongs to the Now Playing controller, not this sheet — it has
    /// to keep running after the sheet is dismissed, which is the entire point.
    ///
    /// And only when this sheet's book is the one Now Playing is driving. The
    /// controller builds its timer in `attach`, capturing *that* coordinator:
    /// before narration has started there is no timer at all, and while a
    /// different book holds Now Playing the timer on offer here would pause
    /// the other book while this one kept narrating. Nil in both cases, which
    /// also disables the control below.
    private var sleepTimer: SleepTimer? {
        guard nowPlaying.coordinator === coordinator else { return nil }
        return nowPlaying.sleepTimer
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
        // On the timer, not the coordinator: an enabled moon over a nil timer
        // was a menu whose every choice silently did nothing.
        .disabled(sleepTimer == nil)
    }

    static func rateText(_ rate: Double) -> String {
        // %g, not %.2g: two *significant* digits printed 1.25 as "1.2" and
        // 1.75 as "1.8" — a menu offering speeds the player never plays.
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate)
    }

    /// A length in units a person says out loud: `4h 12m`, `47m`, `1h 0m`.
    ///
    /// Not `timeText`. That prints `4:12:00`, which is a correct clock reading
    /// and the wrong thing here: beside a scrubber, a colon-separated figure
    /// reads as a position in the book rather than an amount of it left.
    ///
    /// Rounded to the nearest minute rather than truncated, so a book with four
    /// hours, twelve minutes and fifty seconds left does not claim 4h 12m for
    /// most of a minute.
    static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0m" }
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// The same length for VoiceOver, which must not be handed `4h 12m`.
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "no time" }
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        let mins = minutes % 60
        let hourPart = hours == 1 ? "1 hour" : "\(hours) hours"
        let minutePart = mins == 1 ? "1 minute" : "\(mins) minutes"
        if hours == 0 { return minutePart }
        return mins == 0 ? hourPart : "\(hourPart) \(minutePart)"
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
