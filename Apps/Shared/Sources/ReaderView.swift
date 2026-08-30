import IssaCore
import IssaRender
import IssaUI
import SwiftUI

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
    /// The last place a finger was, so a long press that never moves still
    /// knows where it happened.
    @State private var touchPoint: CGPoint = .zero
    @State private var selecting = false
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
            let pageSize = CGSize(
                width: max(geometry.size.width - model.style.pageMargin * 2, 1),
                height: max(geometry.size.height - model.style.pageMargin * 2 - 44, 1),
            )

            ZStack {
                model.style.theme.background.ignoresSafeArea()

                switch model.phase {
                case let .loading(message):
                    VStack(spacing: Metrics.spacing12) {
                        ProgressView()
                        Text(message).font(Typography.footnote).foregroundStyle(Palette.inkTertiary)
                    }
                case let .failed(reason):
                    ContentUnavailableView(
                        "Couldn't open this book",
                        systemImage: "book.closed",
                        description: Text(reason),
                    )
                case .ready:
                    pageContent(size: pageSize)
                }
            }
            .task(id: geometry.size) {
                if case .loading = model.phase {
                    await model.open(pageSize: pageSize)
                } else {
                    await model.resize(to: pageSize)
                }
            }
        }
        #if !os(tvOS)
        .navigationBarBackButtonHidden(false)
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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
        }
        #endif
    }

    @ViewBuilder
    private func pageContent(size: CGSize) -> some View {
        VStack(spacing: 0) {
            PageCanvas(model: model, pageSize: size)
                .padding(model.style.pageMargin)
                .contentShape(Rectangle())
                #if !os(tvOS)
                .onTapGesture { location in
                    // A tap with something selected dismisses the selection,
                    // the way it does everywhere else — it must not also turn
                    // the page out from under the reader.
                    if model.selection != nil {
                        model.clearSelection()
                        return
                    }
                    Task {
                        // In a narrated book, tapping a sentence plays it. The
                        // tap arrives in the padded frame's space, so the margin
                        // comes off before the layout is asked what is there.
                        if model.style.tapToPlay, model.readalong != nil {
                            let margin = model.style.pageMargin
                            let inCanvas = CGPoint(x: location.x - margin, y: location.y - margin)
                            if await model.playSentence(at: inCanvas) { return }
                        }
                        // Otherwise the usual zones: left third back, rest
                        // forward — including every tap that missed a sentence,
                        // so the page can always be turned by tapping.
                        if location.x < size.width * 0.33 { await model.previousPage() }
                        else { await model.nextPage() }
                    }
                }
                // Press and hold selects the sentence under the finger, then
                // dragging adjusts it. Two simultaneous gestures rather than a
                // sequence: a hold that never moves produces no drag value at
                // all, so a sequenced pair would select nothing until the finger
                // happened to slide.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            touchPoint = value.location
                            guard selecting else { return }
                            model.extendSelection(to: canvasPoint(value.location))
                        }
                        .onEnded { _ in selecting = false },
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.35)
                        .onEnded { _ in
                            selecting = true
                            model.beginSelection(at: canvasPoint(touchPoint))
                        },
                )
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            guard model.selection == nil else { return }
                            Task {
                                if value.translation.width < -24 { await model.nextPage() }
                                else if value.translation.width > 24 { await model.previousPage() }
                            }
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
            model.style = settings.readerStyle
            model.preferredRate = settings.playbackRate
            model.enqueuePosition = { [weak app = app] locator, timestamp in
                await app?.enqueue(
                    .position, bookUUID: model.book.uuid,
                    payload: MutationDrain.PositionPayload(locator: locator, timestamp: timestamp),
                )
            }
            model.onSaveAnnotation = { [weak app = app] in app?.save($0) }
            model.onDeleteAnnotation = { [weak app = app] in app?.delete($0) }
            model.setReaderVisible(true)
            nowPlaying.attach(
                coordinator: model.readalong,
                book: model.book,
                session: model.readerSession,
                chapterTitle: { model.chapterTitle },
            )
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
        .onChange(of: settings.readerStyle) { _, style in model.style = style }
        .onDisappear { model.setReaderVisible(false) }
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
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, Metrics.spacing16)
        .padding(.vertical, Metrics.spacing12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.bottom, Metrics.spacing24)
        .transition(.opacity)
    }
    #endif

    /// Tap coordinates arrive in the padded frame's space; the layout speaks
    /// in the canvas's, which starts one margin in.
    private func canvasPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - model.style.pageMargin, y: point.y - model.style.pageMargin)
    }

    private var footer: some View {
        HStack(spacing: Metrics.spacing12) {
            if model.hasNarration {
                Button {
                    Task { await model.togglePlayback() }
                } label: {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Palette.tangerine)
                }
                .buttonStyle(.plain)
                Button {
                    showsPlayer = true
                } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 17))
                        .foregroundStyle(Palette.inkTertiary)
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
            Spacer()
            if model.pageCount > 0 {
                Text("\(model.pageIndex + 1) / \(model.pageCount)")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(model.style.theme.text.opacity(0.55))
            }
        }
        .padding(.horizontal, model.style.pageMargin)
        .frame(height: 44)
    }
}

/// Draws one page, plus the read-along highlight when audio is playing.
struct PageCanvas: View {
    let model: ReaderModel
    let pageSize: CGSize

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            guard let layout = model.layout, let page = model.currentPage else { return }

            // Everything tinted is drawn beneath the glyphs so it reads as
            // paper tint rather than a wash over the type.
            for (rect, tint) in model.highlightRects(on: page) {
                let rounded = Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 3)
                context.fill(rounded, with: .color(ReaderPalette.color(for: tint).opacity(0.30)))
            }
            if let fragment = model.activeFragmentID {
                for rect in layout.highlightRects(forFragment: fragment, on: page) {
                    let rounded = Path(roundedRect: rect.insetBy(dx: -2, dy: -1), cornerRadius: 3)
                    context.fill(rounded, with: .color(model.style.theme.highlight))
                }
            }
            if let selection = model.selection {
                for rect in layout.rects(forRange: selection, on: page) {
                    context.fill(
                        Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 2),
                        with: .color(Palette.tangerine.opacity(0.28)),
                    )
                }
            }

            context.withCGContext { cgContext in
                layout.draw(page: page, in: cgContext)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .clipped()
        // A Canvas is a drawing: to VoiceOver the page is blank unless the text
        // is stated. Reading the page as one element rather than per paragraph
        // matches how the page turns — there is nothing to navigate between,
        // because the next paragraph may be on the next page.
        .accessibilityElement()
        .accessibilityLabel(model.currentPageText)
        .accessibilityValue(
            model.pageCount > 0 ? "Page \(model.pageIndex + 1) of \(model.pageCount)" : "")
        .accessibilityHint("Swipe up or down to turn the page")
        .accessibilityAddTraits(.isStaticText)
        .accessibilityAction(named: "Next page") { Task { await model.nextPage() } }
        .accessibilityAction(named: "Previous page") { Task { await model.previousPage() } }
        .accessibilityAction(named: "Bookmark this page") { model.toggleBookmark() }
    }
}
