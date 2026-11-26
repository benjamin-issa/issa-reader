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
    /// What is holding this view, and therefore whether it may take all the
    /// height it is offered.
    ///
    /// A sheet's height is the sheet's business — the detents decide it, and the
    /// stack fills whatever they settle on so the composer stays at the top
    /// rather than floating in the middle. A panel's height is the *content's*
    /// business: a popover is sized by what is inside it, so a stack that always
    /// claims the full height reports a height that means nothing, and the
    /// scroller wrapped around it never learns there is anything to scroll.
    enum Layout {
        case sheet
        case panel

        /// Whether the stack grows to fill the height on offer rather than
        /// reporting its own.
        var fillsOfferedHeight: Bool { self == .sheet }
    }

    let model: ReaderModel
    var layout: Layout = .sheet
    @Environment(AskCoordinator.self) private var coordinator
    @Environment(PlaybackSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var chips: [String] = AskSuggestions.chips(topNames: [])
    @State private var availability = AskAvailability.current()
    /// Whether "Use Apple's servers" is offered, and whether it can be used.
    @State private var cloud: CloudAvailability = .unavailable(reason: "not read yet")
    /// Where this question goes. Starts at the Settings default for every new
    /// question, so choosing Apple's servers or a provider once never quietly
    /// sends the next one there too.
    @State private var choice: AskAnswerer = .device
    /// Whether the servers' availability has been read since the sheet opened.
    /// The question's starting choice is set from it once; the task that
    /// reads it runs again when the book finishes opening, and resetting the
    /// choice then overwrote a switch the reader had just turned — sending a
    /// question they had kept on the device to Apple's servers.
    @State private var cloudRead = false
    /// Whether the last Send arrived before the book had finished laying out.
    ///
    /// A flag rather than a computed check on the reader, because the two things
    /// it would have to ask — `askSource()` and `readingBoundary()` — build a
    /// `BookSource` and read the layout, and doing that on every render pass is
    /// the mistake `showsAskPill` was making a few files away.
    @State private var isStillOpening = false
    @FocusState private var fieldFocused: Bool

    /// Reported upwards so the presenting sheet can grow from medium to large
    /// when an answer needs the room. Measured rather than guessed: a two-line
    /// answer in a half sheet and a nine-line one in the same half sheet are
    /// different failures.
    var onContentHeight: ((CGFloat) -> Void)?

    private var job: AskJob? { coordinator.job(for: model.book.uuid) }

    /// The reader's own providers. Empty for nearly everyone, and then the
    /// sheet is exactly what it was: no picker until a key is registered.
    private var providers: [ProviderKind] { coordinator.keys.registered }

    /// Whether anything here can answer: the device, or a reader's own key —
    /// which brings Ask to a device that cannot run Apple Intelligence.
    private var canAsk: Bool { coordinator.canAsk(deviceReady: availability.isReady) }

    /// The places this question could go, for the picker.
    private var choices: [AskAnswerer] {
        AskDefaults.choices(
            registered: providers, deviceSupported: AskDefaults.supported(availability),
            cloudUsable: availability.isReady && cloud.isUsable,
        )
    }

    /// The model the pill names, for a question going to a reader's provider.
    private var pillModel: String? {
        if let name = job?.providerModelName { return name }
        guard let kind = choice.provider else { return nil }
        return coordinator.keys.registration(for: kind)?.model.displayName
    }

    /// What the pill at the foot of the sheet has to say, when it has anything.
    ///
    /// Nil for an "Apple Intelligence is off" sentence and for a failure, which
    /// have nothing to disclose either way, and nil for `.withheld` — an
    /// answered state with nothing behind it: the "not yet" sentinel is a
    /// constant in this repo, and the pill under it used to say a machine had
    /// written it.
    ///
    /// Not nil for the composer, which is the change. The reader deciding
    /// whether to type is the one who most needs to know the answer will be
    /// worked out here, and the pill said nothing at all until an answer
    /// existed. The working state gets the same wording rather than none, so a
    /// pill does not blink out for the twenty seconds a generation takes.
    private var originState: AskOriginState? {
        guard canAsk else { return nil }
        switch job?.state {
        case .none:
            return .unanswered(choice)
        case .working:
            return .unanswered(job?.answeredBy ?? .device)
        case let .answered(answer):
            return answer.origin == .withheld ? nil : .answered(answer.origin, job?.answeredBy ?? .device)
        case .failed:
            return nil
        }
    }

    /// The question's starting choice: the reader's default, where the servers
    /// can take a question at all.
    private func resetAnswerer() {
        choice = AskDefaults.answerer(
            settings: settings, registered: providers,
            deviceSupported: AskDefaults.supported(availability),
            cloudUsable: availability.isReady && cloud.isUsable,
        )
        if choice == .cloud { coordinator.prepareCloud() }
    }

    var body: some View {
        Group {
            if layout.fillsOfferedHeight {
                // Scrolls when it has to. At the largest accessibility sizes,
                // with the keyboard up, the header, the field, the picker and
                // its caption are taller than a sheet, and a stack that cannot
                // scroll pushed the title and Done off the top (1.8.0's sweep).
                // At least the height on offer, so the pill still sits at the
                // foot when everything fits.
                GeometryReader { proxy in
                    ScrollView {
                        stack.frame(minHeight: proxy.size.height, alignment: .topLeading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            } else {
                stack
            }
        }
        .background(Palette.paper)
        // Keyed on whether the book has finished opening. The sparkle opens
        // this sheet while the book is still laying out, when there is no file
        // to warm up from, and a bare `.task` ran once, found nothing, and was
        // never run again: no warm-up for that book at all, so the reader's
        // question built the index itself — and a warm-up started by the next
        // opening raced it over the same file.
        .task(id: model.package != nil) {
            // Availability can have changed since the app launched — the reader
            // may have been to Settings and turned Apple Intelligence on — and
            // this is the moment the copy has to be right.
            coordinator.keys.refresh()
            availability = coordinator.deviceAvailability()
            cloud = coordinator.cloudAvailability()
            if job == nil, !cloudRead { resetAnswerer() }
            cloudRead = true
            // Before the availability guard: a notification was delivered while
            // Apple Intelligence was on, and turning it off afterwards must not
            // leave the banner about it sitting on the lock screen for ever.
            coordinator.reopened(bookUUID: model.book.uuid)
            // The index is built and the chips found wherever something can
            // answer. Nothing in this is a request to a provider: the device's
            // model is warmed only where it is ready (`AskCoordinator.prepare`).
            guard canAsk else { return }
            coordinator.prepare(for: model)
            chips = await coordinator.suggestions(for: model)
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            header
            content
            // Pushed to the foot of the sheet, and outside the answer's own
            // `VStack`: that one is measured to decide between the medium and
            // large detents, and a pill that grew the measurement would open
            // sheets full-height to make room for a caption.
            if let originState {
                Spacer(minLength: 0)
                AskOriginPill(state: originState, providerModel: pillModel)
            }
        }
        .padding(Metrics.spacing24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
        if !canAsk {
            unavailable
        } else if let job {
            switch job.state {
            case .working: working(job)
            case let .answered(answer):
                // An answer with no prose in it is a failure that got this far.
                // The engine refuses those now, so this is the last line of
                // defence — and it is the line that would have turned 1.2.0
                // (41)'s blank card into a sentence the reader could act on.
                if answer.text.isEmpty {
                    failed(job, .other(AskFailure.couldNotAnswer))
                } else {
                    answered(job, answer)
                }
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

            if providers.isEmpty {
                // 1.8.0's switch, unchanged, for every reader without a key.
                if cloud.offersSwitch {
                    appleServersSwitch
                }
            } else if choices.count > 1 {
                answererPicker
            } else {
                // One place only — a key on a device that cannot run Apple
                // Intelligence. No one-row menu (the iOS 27 pill the owner
                // rejected): just where the question goes.
                Text(AskDefaults.caption(for: choice, authMethod: choiceAuthMethod))
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask.answerer.caption")
            }

            // Six, wrapped. Two of them were two spellings of the same idea —
            // "Who is X?" and the recap — and a reader who wanted to know what
            // the feature could do learned that it did those two things.
            //
            // `FlowRow` rather than an `HStack` that clips or a scroller: the
            // chips are different lengths, a fixed row leaves the last one half
            // off the screen, and `AskSourcesRow` explains why a horizontal
            // scroller inside a sheet detent is a gesture fight. It is the same
            // layout the book details screen wraps its tags with.
            FlowRow(spacing: Metrics.spacing8) {
                ForEach(chips, id: \.self) { chip in
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

            // The chips take the same path as the field, so they need the same
            // answer: tapping one before the book is laid out used to do
            // nothing at all.
            if isStillOpening {
                Text("Still opening this book. Try again in a moment.")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask.stillOpening")
            }
        }
        // Focused on appear, not on the sheet's: the reader opened this to type.
        // And every new question starts at the reader's default.
        .onAppear {
            fieldFocused = true
            resetAnswerer()
        }
    }

    /// "Use Apple's servers", and the one sentence that says what that means.
    ///
    /// Worded for a reader rather than an engineer: what leaves the device (the
    /// question and passages of this book) and where it goes (Apple). What
    /// Apple does with it is Apple's to say, on the page Settings links to.
    /// "Private Cloud Compute" is Apple's name for it and lives in the pill.
    private var appleServersSwitch: some View {
        let useAppleServers = Binding(
            get: { choice == .cloud },
            set: { choice = $0 ? .cloud : .device },
        )
        return VStack(alignment: .leading, spacing: Metrics.spacing4) {
            Toggle(isOn: useAppleServers) {
                Text("Use Apple's servers")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.ink)
            }
            .toggleStyle(.switch)
            .tint(Palette.tangerine)
            .disabled(!cloud.isUsable)
            .accessibilityIdentifier("ask.appleServers")
            Text(Self.appleServersCaption(for: cloud))
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ask.appleServers.caption")
        }
        .onChange(of: choice) { _, now in
            if now == .cloud { coordinator.prepareCloud() }
        }
    }

    /// Where this question goes, once the reader has a key of their own: this
    /// device, Apple's servers, or their provider. A menu rather than a
    /// segmented control, because four places do not fit a phone's width at
    /// the larger text sizes — and never a one-row menu (`ios27` pill).
    private var answererPicker: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            // The label drawn beside the menu: a menu picker on iOS shows only
            // its selection, and "This iPhone ⌄" on its own does not say what
            // it chooses.
            HStack(spacing: Metrics.spacing8) {
                Text("Answer with")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: Metrics.spacing8)
                Picker("Answer with", selection: $choice) {
                    ForEach(choices, id: \.self) { answerer in
                        Text(AskDefaults.choiceTitle(
                            answerer,
                            model: answerer.provider.flatMap { coordinator.keys.registration(for: $0)?.model.displayName },
                        ))
                        .tag(answerer)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(Palette.tangerine)
                .accessibilityIdentifier("ask.answerer")
            }
            // The device chosen while it cannot answer yet — Apple
            // Intelligence off or downloading — says why, rather than the
            // question going somewhere the reader did not pick.
            Text(choice == .device && !availability.isReady
                ? Self.unavailableSentence(for: availability)
                : AskDefaults.caption(for: choice, authMethod: choiceAuthMethod))
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ask.answerer.caption")
        }
        .onChange(of: choice) { _, now in
            if now == .cloud { coordinator.prepareCloud() }
        }
    }

    private var choiceAuthMethod: AIKeys.AuthMethod {
        choice.provider.flatMap { coordinator.keys.registration(for: $0)?.authMethod } ?? .apiKey
    }

    /// The sentence under the switch. Static and pure so a test can hold it to
    /// saying what leaves the device.
    static func appleServersCaption(for cloud: CloudAvailability) -> String {
        if case let .limitReached(resetDate) = cloud {
            return AskFailure.cloudLimitReached(resetDate: resetDate).message(deviceNoun: AskDevice.noun)
        }
        return appleServersSentence
    }

    static let appleServersSentence =
        "Sends your question and passages from this book to Apple to answer."


    /// Sends the question, or says why it could not be sent.
    ///
    /// `ask` returns nil whenever the reader's position or the book's file is
    /// not available yet, and both are missing for the second or two a book
    /// takes to lay out — which is exactly when a reader who tapped the sparkle
    /// on the way in is typing. The `@discardableResult` was discarded: the
    /// field was wiped, the keyboard went down, and nothing whatever happened,
    /// with no message. The question is kept and the keyboard with it, because
    /// the fix for this is to tap Send again a moment later.
    private func send() {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        // What the reader chose, if it can still take a question.
        let answerer: AskAnswerer = choices.contains(choice) ? choice : (choices.first ?? .device)
        // The device, chosen while it cannot answer yet: the caption already
        // says why, and the question stays in the field.
        if answerer == .device, !availability.isReady { return }
        guard coordinator.ask(asked, in: model, answerer: answerer) != nil else {
            isStillOpening = true
            return
        }
        isStillOpening = false
        fieldFocused = false
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

            // Inside this stack on purpose — see `AskSourcesRow`. It is part of
            // the answer, so the height an opened excerpt adds is height the
            // sheet should grow to fit, and the measurement below already does
            // that.
            AskSourcesRow(
                sources: answer.sources,
                title: { model.title(inSpineItem: $0.passage.spineIndex,
                                     atOffset: $0.passage.start) },
                onOpen: openInTheBook,
            )

            // The reader sent this to Apple's servers and the device answered:
            // said, because it is not what they chose.
            if job.fellBackToDevice {
                Text(Self.fellBackSentence(for: job.fallback ?? .unreachable))
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask.fellBack")
            }

            // Kept on the boundary rather than written here, so the popover and
            // the sheet cannot come to word the same claim differently.
            Text(job.boundary.footer)
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

    /// Leaves for the cited paragraph.
    ///
    /// A departure rather than a detour, and deliberately so: closing the sheet
    /// discards the answer — that is what `sheetDismissed` does with an answered
    /// job, and what keeps "nothing is written down" true — so the reader who
    /// taps a source has chosen the book over the answer. The excerpt is read
    /// out of the source before the sheet goes, because the job it belongs to
    /// goes with it.
    private func openInTheBook(_ source: AskSource) {
        let passage = source.passage
        dismiss()
        Task { await model.go(to: passage) }
    }

    // MARK: - Failure and unavailability

    private func failed(_ job: AskJob, _ failure: AskFailure) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            askedQuestion(job.question)
            Text(failure.message(deviceNoun: AskDevice.noun, answerer: job.answeredBy))
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Metrics.spacing16) {
                // The place the reader chose, again — not wherever the switch
                // in Settings happens to point now.
                Button("Try again") {
                    coordinator.ask(job.question, in: model, answerer: job.answerer)
                }
                .font(Typography.callout.weight(.semibold))
                .foregroundStyle(Palette.tangerine)
                // Apple's servers or the reader's provider refused, ran out or
                // could not be reached: the device may well answer, and asking
                // it is the reader's call — where it can answer at all.
                if job.answeredBy != .device, failure.offersDeviceInstead, availability.isReady {
                    Button("Answer on this \(AskDevice.noun)") {
                        coordinator.ask(job.question, in: model, answerer: .device)
                    }
                    .font(Typography.callout)
                    .foregroundStyle(Palette.tangerine)
                    .accessibilityIdentifier("ask.answerOnDevice")
                }
                Button("Done") { dismiss() }
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkSecondary)
                Spacer()
            }
        }
    }

    static func fellBackSentence(for reason: AskJob.Fallback) -> String {
        switch reason {
        case .unreachable:
            "Couldn't reach Apple's servers, so this was answered on your \(AskDevice.noun)."
        case .declined:
            "Apple's servers declined this one, so it was answered on your \(AskDevice.noun)."
        }
    }

    /// One sentence, and never a toggle: a switch that can do nothing is worse
    /// than an explanation.
    private var unavailable: some View {
        Text(Self.unavailableSentence(for: availability))
            .font(Typography.body)
            .foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What the sheet says when the device could answer but is not ready to.
    ///
    /// Both of those states end with the way to hide the button, because Ask is
    /// on by default: a reader who opened this sheet by tapping a sparkle they
    /// never asked for needs the way out as much as the way forward.
    static func unavailableSentence(for availability: AskAvailability) -> String {
        switch availability {
        case .appleIntelligenceOff:
            "Apple Intelligence is turned off. \(AskDevice.turnOnSentence) \(AskDevice.hideButtonSentence)"
        case .modelDownloading:
            "Apple Intelligence is still downloading its model to this \(AskDevice.noun). Asking will work once it finishes. \(AskDevice.hideButtonSentence)"
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
