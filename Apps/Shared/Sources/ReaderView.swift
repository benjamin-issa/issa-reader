import IssaCore
import IssaRender
import IssaUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The reading surface.
///
/// A page is drawn straight from the chapter's existing TextKit 2 layout, so
/// turning a page translates geometry rather than laying anything out again.
public struct ReaderView: View {
    @State private var model: ReaderModel
    @State private var showsPlayer = false
    @State private var showsContents = false
    @State private var showsSearch = false
    @State private var showsAnnotations = false
    @State private var showsTypography = false
    /// The last place a finger was, so a long press that never moves still
    /// knows where it happened.
    @State private var touchPoint: CGPoint = .zero
    @State private var selecting = false
    /// The device's unsafe edges, sampled once. See `ReaderInsets`.
    @State private var deviceInsets = EdgeInsets()
    /// Whether a finger is currently down, so `selecting` can be cleared at the
    /// start of a touch rather than the end of one.
    @State private var touching = false
    @Environment(\.dismiss) private var dismiss
    @Environment(NowPlayingController.self) private var nowPlaying
    @Environment(PlaybackSettings.self) private var settings
    @Environment(AppModel.self) private var app
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    private var isActiveScene: Bool { controlActiveState == .key }
    #endif

    public init(book: Book, session: Session) {
        _model = State(initialValue: ReaderModel(book: book, session: session))
    }

    public var body: some View {
        GeometryReader { geometry in
            // The whole window, not the safe-area content box. Measuring
            // against the live safe area is what made the page re-paginate
            // every time the chrome was toggled: hiding a bar changes the
            // inset, the inset changes this size, and the size is the id of
            // the task below.
            let pageSize = CGSize(
                width: max(geometry.size.width - model.style.pageMargin * 2, 1),
                height: max(
                    geometry.size.height - deviceInsets.top - deviceInsets.bottom
                        - model.style.pageMargin * 2 - 44, 1),
            )

            ZStack {
                model.style.theme.background.ignoresSafeArea()

                switch model.phase {
                case let .loading(message):
                    VStack(spacing: Metrics.spacing12) {
                        ProgressView()
                        Text(message).font(Typography.footnote).foregroundStyle(model.style.theme.textTertiary)
                    }
                case let .downloading(received, total):
                    downloadingView(received: received, total: total)
                case let .failed(reason):
                    // Coloured from the page's own theme, not the system's.
                    // The reader's themes deliberately ignore the device
                    // appearance, so a system-coloured view here is white on
                    // cream for anyone reading `paper` in Dark Mode.
                    VStack(spacing: Metrics.spacing12) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 34))
                            .foregroundStyle(model.style.theme.text.opacity(0.45))
                        Text("Couldn't open this book")
                            .font(Typography.headline)
                            .foregroundStyle(model.style.theme.text)
                        Text(reason)
                            .font(Typography.footnote)
                            .foregroundStyle(model.style.theme.text.opacity(0.7))
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            Task { await model.retryOpen(pageSize: pageSize) }
                        }
                        .font(Typography.callout.weight(.semibold))
                        .foregroundStyle(model.style.theme.accent)
                    }
                    .padding(Metrics.spacing32)
                case .ready:
                    pageContent(size: pageSize)
                }
            }
            .task(id: geometry.size) {
                // Set before open(), not in pageContent's onAppear — that only
                // renders once the book is already open, so the reader always
                // fell back to the old blocking foreground download.
                model.downloadHost = app
                switch model.phase {
                case .loading, .downloading:
                    // Re-entering while downloading is safe and necessary: the
                    // transfer belongs to the background session, but the wait
                    // for it lived in this task, and a geometry change cancels
                    // the task. Without re-attaching, a layout pass mid-download
                    // reported "Download cancelled" over a transfer still running.
                    await model.open(pageSize: pageSize)
                case .ready:
                    await model.resize(to: pageSize)
                case .failed:
                    // resize() guards on the size having changed, and open()
                    // already assigned this one — so routing failure here was
                    // an early return every time, with no way back into the
                    // book but dismissing it. The retry button is the way out.
                    break
                }
            }
            // The page sits inside the device's own unsafe edges, held rather
            // than observed, so nothing the chrome does can move it.
            .padding(.top, deviceInsets.top)
            .padding(.bottom, deviceInsets.bottom)
            // Re-sample on a genuine size change — a rotation or a split view
            // — where the unsafe edges really are different. A chrome toggle
            // does not change the window's size, so it never lands here.
            .onChange(of: geometry.size, initial: true) { deviceInsets = ReaderInsets.current() }
        }
        // Measure the window, not the safe-area content box.
        .ignoresSafeArea()
        #if os(iOS)
        // Hidden for the whole screen rather than toggled. Toggling them is
        // what changed the safe area, and the safe area is what re-paginated
        // the chapter — so the reader's own chrome is drawn over the page
        // instead, and these never move again. Both Storyteller and Silveran
        // Reader take the bars out of the reader entirely for the same reason.
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!model.chromeVisible)
        // Dismisses the home indicator with the rest of it.
        .persistentSystemOverlays(model.chromeVisible ? .automatic : .hidden)
        #endif
        .onDisappear { Task { await model.saveProgress() } }
        #if os(iOS) || os(macOS)
        // Handoff: the same book, at the same place, on the Mac or the iPad.
        .userActivity(BookActivity.type) { activity in
            let made = BookActivity.make(book: model.book, progress: model.bookProgress)
            activity.title = made.title
            activity.userInfo = made.userInfo
            activity.requiredUserInfoKeys = made.requiredUserInfoKeys
            activity.isEligibleForHandoff = true
        }
        #endif
        #if !os(tvOS)
        .sheet(isPresented: $showsContents) {
            NavigationStack {
                ChapterListView(model: model) { index, fragment in
                    Task { await model.go(toChapter: index, fragment: fragment) }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsPlayer) {
            PlayerView(book: model.book, session: model.readerSession, coordinator: model.readalong)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showsSearch) {
            NavigationStack {
                BookSearchView(model: model) { hit in
                    Task { await model.go(to: hit, matching: hit.excerpt) }
                }
            }
        }
        .sheet(isPresented: $showsAnnotations) {
            NavigationStack {
                AnnotationsView(model: model) { annotation in
                    Task { await model.go(to: annotation) }
                }
            }
            .presentationDetents([.medium, .large])
        }
        #if os(macOS)
        // The Mac keeps a real toolbar: its window chrome never moved the page.
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { readerActions } }
        #else
        // Drawn over the page rather than above it, so showing it cannot
        // change the page's size.
        .overlay(alignment: .top) { topBar }
        #endif
        #endif
    }

    /// Puts the settings, this book's own departures from them, and the face
    /// found inside the book together into the style the page is set in.
    ///
    /// `publisherFamily` is carried across by hand: it is discovered while
    /// opening and belongs to the book, so it is not in either stored value.
    private func applyStyle() {
        var resolved = settings.style(for: model.book.uuid)
        resolved.publisherFamily = model.style.publisherFamily
        model.style = resolved
    }

    /// Bookmark, and the rest behind an ellipsis.
    @ViewBuilder
    private var readerActions: some View {
        Button { showsTypography = true } label: {
            Image(systemName: "textformat.size")
        }
        .accessibilityLabel("Text options for this book")

        Button { model.toggleBookmark() } label: {
            Image(systemName: model.isPageBookmarked ? "bookmark.fill" : "bookmark")
        }
        .accessibilityLabel(model.isPageBookmarked ? "Remove bookmark" : "Bookmark this page")

        Menu {
            Button("Find in book", systemImage: "magnifyingglass") { showsSearch = true }
            Button("Marks", systemImage: "bookmark.square") { showsAnnotations = true }
            Button("Contents", systemImage: "list.bullet") { showsContents = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    #if os(iOS)
    /// The reader's own top bar, floating over the page.
    private var topBar: some View {
        HStack(spacing: Metrics.spacing16) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Back to the book")
            Spacer()
            readerActions
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(model.style.theme.text)
        .padding(.horizontal, Metrics.spacing16)
        .frame(height: 44)
        .padding(.top, deviceInsets.top)
        .background {
            // The page's own colour, not a material: the reader's theme is
            // independent of the device appearance, and a system material
            // goes dark over a light page.
            model.style.theme.background
                .opacity(0.94)
                .ignoresSafeArea()
        }
        .opacity(model.chromeVisible ? 1 : 0)
        // Untappable when invisible, so a tap in the top strip turns the page
        // like anywhere else rather than hitting a control that is not there.
        .allowsHitTesting(model.chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: model.chromeVisible)
    }
    #endif

    @ViewBuilder
    private func pageContent(size: CGSize) -> some View {
        VStack(spacing: 0) {
            PageCanvas(model: model, pageSize: size)
                .padding(model.style.pageMargin)
                .contentShape(Rectangle())
                #if !os(tvOS)
                // Double tap first: SwiftUI gives the higher count priority,
                // and this is the gesture that used to be a single tap — which
                // made every tap ambiguous, and because it was tested before the
                // page zones it left "tap left to go back" unreachable over any
                // narrated text.
                .modifier(
                    ReadAloudDoubleTap(
                        enabled: model.hasNarration && model.style.tapToPlay,
                    ) { location in
                        model.clearSelection()
                        Task { await model.playSentence(at: canvasPoint(location)) }
                    },
                )
                .onTapGesture { location in
                    // A tap with something selected dismisses it, the way it
                    // does everywhere else, and does nothing more.
                    if model.selection != nil {
                        model.clearSelection()
                        return
                    }
                    switch ReaderTapZone.of(
                        x: location.x, pageWidth: size.width, margin: model.style.pageMargin,
                    ) {
                    case .back: Task { await model.previousPage() }
                    case .forward: Task { await model.nextPage() }
                    case .middle: model.toggleChrome()
                    }
                }
                // One drag recogniser for the whole page: it tracks the
                // finger for selection, and on lift-off decides whether the
                // movement was a page turn. A second DragGesture(minimumDistance:
                // 24) alongside this one never fired at all — SwiftUI gave the
                // touch to whichever drag claimed it first — which is why
                // swiping to turn a page did nothing.
                //
                // Press and hold selects the sentence under the finger, then
                // dragging adjusts it. Simultaneous with the long press rather
                // than sequenced after it: a hold that never moves produces no
                // drag value at all, so a sequenced pair would select nothing
                // until the finger happened to slide.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Cleared at the START of a touch rather than on
                            // lift-off, because `onEnded` below has to be able
                            // to tell whether THIS finger made a selection —
                            // and it cannot do that if the flag is reset by the
                            // same lift it wants to read.
                            if !touching {
                                touching = true
                                selecting = false
                            }
                            touchPoint = value.location
                            guard selecting else { return }
                            model.extendSelection(to: canvasPoint(value.location))
                        }
                        .onEnded { value in
                            touching = false
                            // A press-and-drag that was adjusting a selection is
                            // not a page turn.
                            if selecting { return }
                            // The leading edge belongs to the navigation stack.
                            // The reader is pushed (BookDetailView's Read
                            // button), so a back-swipe starting there pops the
                            // book shut — unguarded it did that AND turned the
                            // page on the way out.
                            guard value.startLocation.x > 20 else { return }
                            guard abs(value.translation.width) >= 24 else { return }
                            // Clear a selection and turn the page in one motion.
                            // Guarding on `selection == nil` meant that once
                            // anything was selected, swiping silently did
                            // nothing at all and nothing said why.
                            if model.selection != nil { model.clearSelection() }
                            Task {
                                if value.translation.width < 0 { await model.nextPage() }
                                else { await model.previousPage() }
                            }
                        },
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.35)
                        .onEnded { _ in
                            model.beginSelection(at: canvasPoint(touchPoint))
                            // Claim the touch only if there was text under it.
                            // A long press on an illustration or a margin
                            // selects nothing, and the finger should still be
                            // free to turn the page — otherwise a slow swipe
                            // over a plate is silently swallowed.
                            selecting = model.selection != nil
                        },
                )
                .overlay(alignment: .bottom) {
                    if model.selection != nil { selectionMenu }
                }
                #endif

            footer
        }
        // A tap outside the menu dismisses the selection, the way every text
        // selection anywhere else does.
        .onChange(of: model.pageIndex) { model.clearSelection() }
        #if os(macOS)
        // Bare arrow keys turn pages, which is what a Mac reader tries first.
        // The menu shortcuts are ⌘-arrow so the two do not collide.
        .focusable()
        .onKeyPress(.rightArrow) { Task { await model.nextPage() }; return .handled }
        .onKeyPress(.leftArrow) { Task { await model.previousPage() }; return .handled }
        .onKeyPress(.space) {
            guard model.hasNarration else { return .ignored }
            Task { await model.togglePlayback() }
            return .handled
        }
        #endif
        .onAppear {
            // Seed from the shared preferences, then follow them: the Reading
            // settings screen is otherwise writing to a value nothing reads.
            applyStyle()
            model.preferredRate = settings.playbackRate
            // The book id is captured by value. Reaching through `model` inside
            // a closure the model itself stores would retain it for the life of
            // the process, pinning the chapter layout, the decoded plates and
            // the readalong coordinator with it.
            let bookUUID = model.book.uuid
            model.enqueuePosition = { [weak app = app] locator, timestamp in
                await app?.enqueue(
                    .position, bookUUID: bookUUID,
                    payload: MutationDrain.PositionPayload(locator: locator, timestamp: timestamp),
                )
                // And into the library's own copy, so the Continue card and the
                // book screen move with the reader rather than with the next
                // fetch.
                app?.recordPosition(locator, timestamp: timestamp, for: bookUUID)
            }
            model.onSaveAnnotation = { [weak app = app] in app?.save($0) }
            model.onDeleteAnnotation = { [weak app = app] in app?.delete($0) }
            model.setReaderVisible(true)
            // Only claim Now Playing if this book actually has narration.
            // Opening a plain ebook used to attach a nil coordinator, which
            // cleared nowPlayingInfo entirely — silencing the lock screen for an
            // audiobook that was still playing in the background.
            if model.readalong != nil {
                nowPlaying.attach(
                    coordinator: model.readalong,
                    book: model.book,
                    session: model.readerSession,
                    // Weak: the controller outlives this screen deliberately,
                    // and holding the reader through it would keep an entire
                    // book in memory after it closed.
                    chapterTitle: { [weak model] in model?.chapterTitle },
                )
            }
        }
        .task { model.loadAnnotations(await app.annotations(for: model.book.uuid)) }
        #if os(macOS)
        // Menu commands arrive as notifications; only the frontmost reader
        // window is active, so only it responds.
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.find.notification)) { _ in
            guard isActiveScene else { return }
            showsSearch = true
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.contents.notification)) { _ in
            guard isActiveScene else { return }
            showsContents = true
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.marks.notification)) { _ in
            guard isActiveScene else { return }
            showsAnnotations = true
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.bookmark.notification)) { _ in
            guard isActiveScene else { return }
            model.toggleBookmark()
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.nextPage.notification)) { _ in
            guard isActiveScene else { return }
            Task { await model.nextPage() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.previousPage.notification)) { _ in
            guard isActiveScene else { return }
            Task { await model.previousPage() }
        }
        #endif
        // A re-resolve, not an assignment: `model.style = settings.readerStyle`
        // would throw away this book's own settings the moment the reader
        // changed a default, mid-page.
        .onChange(of: settings.readerStyle) { _, _ in applyStyle() }
        .sheet(isPresented: $showsTypography) {
            BookTypographyView(
                book: model.book,
                publisherFamily: model.style.publisherFamily,
                publisherNote: model.publisherFontDescription,
                onChange: applyStyle,
            )
        }
        .onDisappear {
            model.setReaderVisible(false)
            // Break the closures the model holds back to this screen's world.
            model.enqueuePosition = nil
            model.onSaveAnnotation = nil
            model.onDeleteAnnotation = nil
        }
    }

    /// What to do with the selected text. Copy first, because that is what a
    /// selection is usually for.
    #if !os(tvOS)
    @ViewBuilder
    private var selectionMenu: some View {
        HStack(spacing: Metrics.spacing16) {
            Button {
                if let text = model.selectedText { Clipboard.copy(text) }
                model.clearSelection()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Menu {
                ForEach(Annotation.Tint.allCases, id: \.self) { tint in
                    Button {
                        model.annotate(kind: .highlight, tint: tint)
                    } label: {
                        Label(tint.title, systemImage: "circle.fill")
                    }
                }
            } label: {
                Label("Highlight", systemImage: "highlighter")
            }

            if model.hasNarration {
                Button {
                    Task {
                        await model.playSelection()
                        model.clearSelection()
                    }
                } label: {
                    Label("Play", systemImage: "play.circle")
                }
            }

            Button {
                model.clearSelection()
            } label: {
                Label("Done", systemImage: "xmark")
            }
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 18))
        .foregroundStyle(model.style.theme.text)
        .padding(.horizontal, Metrics.spacing16)
        .padding(.vertical, Metrics.spacing12)
        // The page's own surface, not `.regularMaterial`. A system material
        // goes dark against a light page whenever the device is in Dark Mode,
        // and the reader's theme has nothing to do with the device's.
        .background(model.style.theme.background, in: Capsule())
        .overlay(Capsule().stroke(model.style.theme.text.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.bottom, Metrics.spacing24)
        .transition(.opacity)
    }
    #endif

    /// What a book looks like while it is still arriving.
    ///
    /// Real bytes and a way out. This used to be a bare spinner reading
    /// "Downloading…" with a sixty-second timeout behind it, so a large
    /// readaloud was indistinguishable from a hang until it failed.
    private func downloadingView(received: Int64, total: Int64) -> some View {
        VStack(spacing: Metrics.spacing16) {
            Text(model.book.title)
                .font(Typography.title)
                .foregroundStyle(model.style.theme.text)
                .multilineTextAlignment(.center)

            if total > 0 {
                ProgressView(value: Double(received), total: Double(total))
                    .tint(model.style.theme.accent)
                    .frame(maxWidth: 280)
                Text("\(Self.sizeText(received)) of \(Self.sizeText(total))")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(model.style.theme.textTertiary)
            } else {
                // No Content-Length: an indeterminate bar is honest, where a
                // bar pinned at zero looks exactly like a stall.
                ProgressView().frame(maxWidth: 280)
                Text(received > 0 ? Self.sizeText(received) : "Starting…")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(model.style.theme.textTertiary)
            }

            Button("Cancel") { model.cancelDownload() }
                .font(Typography.callout)
                .foregroundStyle(model.style.theme.textSecondary)
        }
        .padding(Metrics.spacing32)
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Tap coordinates arrive in the padded frame's space; the layout speaks
    /// in the canvas's, which starts one margin in.
    private func canvasPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - model.style.pageMargin, y: point.y - model.style.pageMargin)
    }

    /// The strip below the page.
    ///
    /// Its 44 pt is reserved whether or not the controls are showing, so
    /// toggling the chrome never changes the page size and never re-paginates
    /// the chapter. Only the controls fade; the progress readout stays, because
    /// it is the one thing a reader who has hidden everything still wants.
    private var footer: some View {
        HStack(spacing: Metrics.spacing12) {
            if model.chromeVisible {
                if model.hasNarration {
                    Button {
                        Task { await model.togglePlayback() }
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(model.style.theme.accent)
                    }
                    .buttonStyle(.plain)
                    Button {
                        showsPlayer = true
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 17))
                            .foregroundStyle(model.style.theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showsContents = true
                } label: {
                    HStack(spacing: Metrics.spacing4) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 13))
                        Text(model.chapterTitle)
                            .font(Typography.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(model.style.theme.text.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            // Always on screen, in either form.
            if !model.progressText.isEmpty {
                Text(model.progressText)
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(model.style.theme.text.opacity(0.55))
                    .contentTransition(.numericText())
                    // The page element already says where the reader is, in
                    // words. Left visible, this would follow it as "3 slash 12".
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, model.style.pageMargin)
        .frame(height: 44)
    }
}

/// Installs the read-aloud double tap only where it could actually fire.
///
/// SwiftUI resolves the higher-count gesture first, so merely having a double
/// tap on the page makes every single tap wait for the double-tap window to
/// lapse. Applied unconditionally — with the narration check inside the closure,
/// as it was — that delay was charged to every page turn and every chrome
/// toggle in every plain ebook, for a gesture that had nothing to play.
#if !os(tvOS)
private struct ReadAloudDoubleTap: ViewModifier {
    let enabled: Bool
    let action: (CGPoint) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture(count: 2) { action($0) }
        } else {
            content
        }
    }
}
#endif

/// Draws one page, plus the read-along highlight when audio is playing.
struct PageCanvas: View {
    let model: ReaderModel
    let pageSize: CGSize

    var body: some View {
        // Read in the body, not inside the renderer closure. Observation tracks
        // what a view's body touches; the Canvas closure runs during the render
        // pass and is not tracked, so reading the narrated fragment only in
        // there left the highlight frozen on one sentence for the whole page —
        // the audio moved and the drawing did not.
        let activeFragment = model.activeFragmentID
        let selection = model.selection
        let page = model.currentPage
        let highlights = page.map { model.highlightRects(on: $0) } ?? []
        let theme = model.style.theme

        Canvas(rendersAsynchronously: false) { context, _ in
            guard let layout = model.layout, let page else { return }

            // Everything tinted is drawn beneath the glyphs so it reads as
            // paper tint rather than a wash over the type.
            for (rect, tint) in highlights {
                let rounded = Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 3)
                context.fill(rounded, with: .color(ReaderPalette.color(for: tint).opacity(0.30)))
            }
            if let activeFragment {
                for rect in layout.highlightRects(forFragment: activeFragment, on: page) {
                    let rounded = Path(roundedRect: rect.insetBy(dx: -2, dy: -1), cornerRadius: 3)
                    context.fill(rounded, with: .color(theme.highlight))
                }
            }
            if let selection {
                for rect in layout.rects(forRange: selection, on: page) {
                    context.fill(
                        Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 2),
                        with: .color(theme.selection),
                    )
                }
            }

            context.withCGContext { cgContext in
                layout.draw(page: page, in: cgContext)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .clipped()
        .modifier(PageAccessibility(model: model))
    }
}

/// What VoiceOver makes of a drawn page.
///
/// Split out because it is the whole accessible surface of the reader: a Canvas
/// is a picture, so unless the text and every action are stated here, none of
/// them exist for a reader using VoiceOver.
struct PageAccessibility: ViewModifier {
    let model: ReaderModel

    func body(content: Content) -> some View {
        content
            .accessibilityElement()
            .accessibilityLabel(model.spokenPageText)
            .accessibilityValue(model.spokenPagePosition)
            // Naming the rotor, because that is the gesture that actually works
            // here. An earlier version promised a vertical swipe, which turns no
            // page on any platform this ships to.
            .accessibilityHint("Use the Actions rotor to turn pages or mark this one")
            .accessibilityTextContentType(.narrative)
            // A three-finger swipe is what people try in every other paged app.
            .accessibilityScrollAction { edge in
                Task {
                    switch edge {
                    case .top, .leading: await model.previousPage()
                    default: await model.nextPage()
                    }
                    Self.announcePage(model)
                }
            }
            // The canvas still carries a tap gesture for sighted readers, and
            // SwiftUI would otherwise synthesise activation from it — a
            // double-tap would start narration at the page's centre. Claiming
            // the default action makes activation mean something sensible.
            .accessibilityAction {
                Task {
                    await model.nextPage()
                    Self.announcePage(model)
                }
            }
            .accessibilityAction(named: "Next page") {
                Task {
                    await model.nextPage()
                    Self.announcePage(model)
                }
            }
            .accessibilityAction(named: "Previous page") {
                Task {
                    await model.previousPage()
                    Self.announcePage(model)
                }
            }
            // Named for what it will actually do, since it is a toggle: an
            // action offered as "Bookmark this page" that silently deletes the
            // bookmark already there is the worst kind of surprise.
            .accessibilityAction(named: model.isPageBookmarked ? "Remove bookmark" : "Bookmark this page") {
                model.toggleBookmark()
            }
            .accessibilityAction(named: "Copy page") {
                Clipboard.copy(model.spokenPageText)
            }
            .accessibilityActions {
                // Selection is made with a long press and a drag, which
                // VoiceOver consumes — so highlighting, and playing a sentence,
                // are otherwise unreachable. These act on the top of the page.
                if model.hasNarration {
                    Button("Play from this page") { Task { await model.playFirstSentenceOnPage() } }
                }
                ForEach(Annotation.Tint.allCases, id: \.self) { tint in
                    Button("Highlight page in \(tint.title)") {
                        model.annotatePage(tint: tint)
                    }
                }
            }
    }

    /// Says where the reader has landed.
    ///
    /// A label that changes under an already-focused element is not spoken —
    /// that is what `updatesFrequently` exists for — so a page turn made from
    /// the rotor would otherwise be met with silence.
    @MainActor
    static func announcePage(_ model: ReaderModel) {
        #if canImport(UIKit) && !os(tvOS)
        UIAccessibility.post(notification: .pageScrolled, argument: model.spokenPagePosition)
        #endif
    }
}
