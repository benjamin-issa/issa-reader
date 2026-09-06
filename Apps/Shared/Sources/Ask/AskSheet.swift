#if !os(tvOS)
import IssaAsk
import IssaUI
import SwiftUI

/// One question, one answer, nothing kept.
///
/// Four states in one view rather than four screens, because they are one
/// thought: the reader asks, waits, reads, and either asks again or closes. A
/// navigation stack between them would put a Back button on a conversation that
/// has nowhere to go back to.
///
/// Done always dismisses, and a working job carries on behind it — which is the
/// point of the whole job model, and the reason the footer says so in words.
struct AskSheet: View {
    let model: ReaderModel
    @Environment(AskCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var chips: [String] = AskSuggestions.chips(topNames: [])
    @State private var availability = AskAvailability.current()
    @FocusState private var fieldFocused: Bool

    /// Reported upwards so the presenting sheet can grow from medium to large
    /// when an answer needs the room. Measured rather than guessed: a two-line
    /// answer in a half sheet and a nine-line one in the same half sheet are
    /// different failures.
    var onContentHeight: ((CGFloat) -> Void)?

    private var job: AskJob? { coordinator.job(for: model.book.uuid) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            header
            content
        }
        .padding(Metrics.spacing24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.paper)
        .task {
            // Availability can have changed since the app launched — the reader
            // may have been to Settings and turned Apple Intelligence on — and
            // this is the moment the copy has to be right.
            availability = AskAvailability.current()
            guard availability.isReady else { return }
            coordinator.prepare(for: model)
            chips = await coordinator.suggestions(for: model)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: Metrics.spacing8) {
            Text("Ask about this book")
                .font(Typography.headline)
                .foregroundStyle(Palette.ink)
            BetaPill()
            Spacer()
            Button("Done") { dismiss() }
                .font(Typography.callout.weight(.semibold))
                .foregroundStyle(Palette.tangerine)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !availability.isReady {
            unavailable
        } else if let job {
            switch job.state {
            case .working: working(job)
            case let .answered(answer): answered(job, answer)
            case let .failed(failure): failed(job, failure)
            }
        } else {
            compose
        }
    }

    // MARK: - Compose

    private var compose: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            TextField("Ask about the story so far…", text: $question)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
                .submitLabel(.go)
                .focused($fieldFocused)
                .onSubmit(send)
                .padding(Metrics.spacing12)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                        .strokeBorder(Palette.border, lineWidth: 1)
                }
                .accessibilityIdentifier("ask.field")

            // Two, never more: a wall of suggestions is a menu, and the field
            // above it is what the feature actually is.
            HStack(spacing: Metrics.spacing8) {
                ForEach(chips.prefix(2), id: \.self) { chip in
                    Button {
                        question = chip
                        send()
                    } label: {
                        Text(chip)
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.inkSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, Metrics.spacing12)
                            .padding(.vertical, Metrics.spacing8)
                            .background(Palette.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // Focused on appear, not on the sheet's: the reader opened this to type.
        .onAppear { fieldFocused = true }
    }

    private func send() {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        fieldFocused = false
        coordinator.ask(asked, in: model)
        question = ""
    }

    // MARK: - Working

    private func working(_ job: AskJob) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            askedQuestion(job.question)

            if let line = job.phaseLine {
                Text(line)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkTertiary)
            }

            if job.partial.isEmpty {
                PlaceholderBars()
            } else {
                Text(job.partial)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
            }

            HStack(spacing: Metrics.spacing16) {
                Button("Cancel") { coordinator.cancel(bookUUID: model.book.uuid) }
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkSecondary)
                Spacer()
            }

            Text("You can close this; you'll be told when the answer is ready.")
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    // MARK: - Answer

    private func answered(_ job: AskJob, _ answer: AskAnswer) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            askedQuestion(job.question)

            Text(answer.text)
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ask.answer")

            // Derived from the boundary that was actually enforced, so the
            // sentence cannot drift from what the SQL did.
            Text(job.boundary.footer(deviceNoun: AskDevice.noun))
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Metrics.spacing16) {
                Button("Ask another") { coordinator.discard(bookUUID: model.book.uuid) }
                    .font(Typography.callout.weight(.semibold))
                    .foregroundStyle(Palette.tangerine)
                // Non-expiring: an answer is the reader's, and a Copy that
                // silently empties itself after two minutes is a Copy that
                // sometimes does nothing.
                Button("Copy") { Clipboard.copy(answer.text, lifetime: nil) }
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkSecondary)
                Spacer()
            }
        }
        // Measured here rather than on the whole sheet: this is the state that
        // can outgrow a medium detent, and the others must not drag it open.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            onContentHeight?(height)
        }
    }

    // MARK: - Failure and unavailability

    private func failed(_ job: AskJob, _ failure: AskFailure) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            askedQuestion(job.question)
            Text(failure.message(deviceNoun: AskDevice.noun))
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Metrics.spacing16) {
                Button("Try again") {
                    coordinator.ask(job.question, in: model)
                }
                .font(Typography.callout.weight(.semibold))
                .foregroundStyle(Palette.tangerine)
                Button("Done") { dismiss() }
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkSecondary)
                Spacer()
            }
        }
    }

    /// One sentence, and never a toggle: a switch that can do nothing is worse
    /// than an explanation.
    private var unavailable: some View {
        Text(unavailableSentence)
            .font(Typography.body)
            .foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var unavailableSentence: String {
        switch availability {
        case .appleIntelligenceOff:
            "Apple Intelligence is turned off. Turn it on in \(AskDevice.settingsPath), then come back."
        case .modelDownloading:
            "Apple Intelligence is still downloading its model to this \(AskDevice.noun). Asking will work once it finishes."
        case .available:
            ""
        case .unsupportedDevice, .unsupportedOnThisPlatform:
            "This \(AskDevice.noun) doesn't support Apple Intelligence, so asking isn't available here."
        }
    }

    private func askedQuestion(_ text: String) -> some View {
        Text(text)
            .font(Typography.callout.weight(.semibold))
            .foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: -

/// Three bars where the answer will be, sweeping.
///
/// A shimmer rather than a spinner because the wait is five to thirty seconds
/// and the shape of what is coming is known: a spinner says "something is
/// happening", these say "prose is coming, here". They are replaced the moment
/// the first words stream in.
private struct PlaceholderBars: View {
    private static let widths: [CGFloat] = [1.0, 0.92, 0.6]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            ForEach(Array(Self.widths.enumerated()), id: \.offset) { index, fraction in
                Capsule()
                    .phaseAnimator([false, true]) { bar, lit in
                        bar.foregroundStyle(lit ? Palette.borderStrong : Palette.border)
                    } animation: { _ in
                        // Staggered, so the three read as one sweep down the
                        // paragraph rather than three things blinking together.
                        .easeInOut(duration: 0.9).delay(Double(index) * 0.12)
                    }
                    .frame(height: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Scaled rather than measured: a `GeometryReader` per bar
                    // would be three layout passes for a shape whose only job
                    // is to be roughly the width of a line of prose.
                    .scaleEffect(x: fraction, anchor: .leading)
            }
        }
        .accessibilityLabel("Working out the answer")
    }
}
#endif
