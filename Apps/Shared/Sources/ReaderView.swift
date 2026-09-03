import IssaCore
import IssaPlayback
import IssaRender
import IssaUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Opens a book, resolving its model at the moment the screen is really shown.
///
/// `ReaderView` takes its model rather than making one, and asking `AppModel`
/// for it has a side effect: a book opened for the first time is registered
/// with the app, which is what keeps its narration alive after the screen
/// closes. A `NavigationLink`'s destination closure can be evaluated before
/// the link is ever followed, so handing `ReaderView` a model from the call
/// site would register books nobody opened.
///
/// Resolved in `onAppear`, not in `body`. `AppModel.readers` is observed by the
/// mini bar, the player sheet and both `onChange(of: app.playback == nil)`
/// handlers, so registering the model from inside a body wrote an observed
/// property in the middle of the update that was reading it — and an eviction
/// (`readerDidClose`) then invalidated this very view, whose body promptly
/// resolved a replacement model behind the closing screen. Held in `@State`
/// once resolved, so nothing the app does to `readers` afterwards can make
/// this screen build a second one.
public struct ReaderScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(PlaybackSettings.self) private var settings
    @State private var model: ReaderModel?
    private let book: Book
    private let session: Session

    public init(book: Book, session: Session) {
        self.book = book
        self.session = session
    }

    public var body: some View {
        ZStack {
            // The page's own ground for the one update before the model lands,
            // so a cover that is sliding up is never briefly the wrong colour.
            settings.readerStyle.theme.background.ignoresSafeArea()
            if let model {
                ReaderView(model: model)
            }
        }
        .onAppear {
            if model == nil { model = app.reader(for: book, session: session) }
        }
    }
}

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
    ///
    /// Sampled at construction rather than left empty until the first
    /// `onChange`. Starting at zero means the first page size is wrong by the
    /// whole notch, and since the layout task is keyed on that size, the book
    /// was opened twice — the first attempt cancelled mid-flight, taking its
    /// position fetch with it and logging a failure for something nothing was
    /// waiting on any more.
    @State private var deviceInsets = ReaderInsets.current()
    /// Whether a finger is currently down, so `selecting` can be cleared at the
    /// start of a touch rather than the end of one.
    @State private var touching = false
    #if !os(tvOS)
    // First-run gesture guide. Persisted so it never returns once dismissed,
    // and split in two so the narrated tip can still appear the first time a
    // narrated book opens even when the zone guide was already seen on a plain
    // one.
    //
    // Not iOS-only: the Mac reader has every gesture the guide explains — the
    // three click zones, double-click to read aloud, click and hold to select —
    // and used to be told about none of them.
    @AppStorage("issa.hasSeenReaderCoach") private var hasSeenReaderCoach = false
    @AppStorage("issa.hasSeenNarrationTip") private var hasSeenNarrationTip = false
    #endif
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaybackSettings.self) private var settings
    @Environment(AppModel.self) private var app
    // The skip buttons move the audio from the strip, so the lock screen has
    // to be told where it landed.
    @Environment(NowPlayingController.self) private var nowPlaying
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    /// The Now Playing panel is a window on the Mac, so the reader opens it
    /// rather than presenting a sheet of its own.
    @Environment(\.openWindow) private var openWindow
    private var isActiveScene: Bool { controlActiveState == .key }
    /// Whether the page holds the keyboard, which is what the bare arrow keys
    /// below depend on. Tracked rather than left to SwiftUI because a sheet
    /// takes the keyboard and does not hand it back: after closing the player —
    /// now one ⌥⌘P away — the arrows did nothing at all until the page was
    /// clicked, and nothing on screen said why.
    @FocusState private var pageHasKeyboardFocus: Bool
    private var anySheetShowing: Bool {
        showsPlayer || showsContents || showsSearch || showsAnnotations || showsTypography
    }
    #endif

    /// Takes the model rather than making one.
    ///
    /// It belongs to `AppModel` now, so that listening to a book outlives the
    /// screen showing it — and so that re-presenting the reader hands back the
    /// same instance instead of a fresh one whose new coordinator would cut the
    /// audio off mid-sentence.
    public init(model: ReaderModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        GeometryReader { geometry in
            // The whole window, not the safe-area content box. Measuring
            // against the live safe area is what made the page re-paginate
            // every time the chrome was toggled: hiding a bar changes the
            // inset, the inset changes this size, and the size is the id of
            // the task below.
            // Both bars are reserved, not just the footer. Subtracting a
            // single 44 left the top bar nothing, so every page laid its first
            // lines into the strip the toolbar paints over.
            let chrome = ReaderChrome(
                safeAreaTop: deviceInsets.top,
                safeAreaBottom: deviceInsets.bottom,
                margin: model.style.pageMargin,
            )
            let pageSize = chrome.pageSize(in: geometry.size)

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
            // Keyed on the page size rather than the window's, because the
            // insets arrive from a separate `onChange` and the ordering between
            // the two is not defined: whichever ran second, the chapter used to
            // be laid out against whatever the first one saw, and `resize` — which
            // guards on the size having changed — could never correct it.
            .task(id: pageSize) {
                // Set before open(), not in pageContent's onAppear — that only
                // renders once the book is already open, so the reader always
                // fell back to the old blocking foreground download.
                model.downloadHost = app
                // The rate for the same reason: open() fixes it into the
                // read-along coordinator, and by the time pageContent's
                // onAppear could run the coordinator is already built — every
                // fresh open narrated at 1× whatever rate the reader saved.
                model.preferredRate = settings.playbackRate
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
        // Visibility is the whole screen's, not `pageContent`'s: that view
        // exists only in the `.ready` branch, so the app learned which book
        // was on screen only once the chapter had laid out — and a deep link
        // to the very book still opening reset the navigation stack under
        // the cover, tearing it down and opening the book again. The book id
        // is captured by value inside `onVisibilityChanged`, so this does not
        // retain the model.
        .onAppear { model.setReaderVisible(true) }
        .onDisappear {
            model.setReaderVisible(false)
            Task { await model.saveProgress() }
            // Released only if nothing is playing it, so a book that is merely
            // read does not pin its chapter layout for the rest of the session.
            //
            // Attached to the whole screen, not to `pageContent`, for the same
            // reason as above: its own onDisappear also fired when a chapter
            // failed to load mid-session, evicting the live model while the
            // reader was still on screen.
            //
            // And deferred a turn. Evicting flips `app.playback`, which the
            // mini bar, the player sheet and two `onChange` handlers observe —
            // written synchronously from here, that landed inside the very
            // update that was dismissing this screen (or tearing the scene
            // down on quit), an update SwiftUI then had to run again.
            Task { @MainActor in app.readerDidClose(model) }
        }
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
        // Not on the Mac, where the player is a window several open books can
        // share rather than a sheet owned by whichever one summoned it.
        #if !os(macOS)
        .sheet(isPresented: $showsPlayer) {
            PlayerView(
                book: model.book, session: model.readerSession,
                coordinator: model.readalong, chapterTitle: model.chapterTitle,
            )
                .presentationDetents([.large])
                // The sheet's own backdrop, which is what shows behind the
                // corner radius and under the home indicator. Without it the
                // content can be right to the edge and the frame around it is
                // still system grey against warm paper.
                .presentationBackground(Palette.paper)
        }
        #endif
        .sheet(isPresented: $showsSearch) {
            NavigationStack {
                BookSearchView(model: model) { hit in
                    // The matched text itself, not the whole excerpt:
                    // `go(to:matching:)` sizes the selection on what it is
                    // handed, and the ±100-character context snippet left a
                    // sentence and a half selected — or, near a chapter's
                    // end, a range past the text that drew nothing at all.
                    Task {
                        await model.go(
                            to: hit, matching: String(hit.excerpt[hit.excerptMatchRange]),
                        )
                    }
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
        // At body level like every other reader sheet, not inside pageContent:
        // that view exists only at `.ready`, while the "Aa" button lives in
        // the always-present chrome — tapped during a download, the flag was
        // set with no sheet modifier in the hierarchy, so nothing happened
        // until the book opened and the sheet then popped up unbidden.
        .sheet(isPresented: $showsTypography) {
            BookTypographyView(
                book: model.book,
                publisherFamily: model.style.publisherFamily,
                publisherNote: model.publisherFontDescription,
                onChange: applyStyle,
            )
        }
        #if os(macOS)
        // The Mac keeps a real toolbar: its window chrome never moved the page.
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { macToolbar } }
        // The reader's colours are the book's theme, not the system's, and the
        // toolbar sits against the page. Without this a Night book gets a light
        // toolbar with dark glyphs floating above a dark page.
        .toolbarBackground(model.style.theme.background, for: .windowToolbar)
        .toolbarColorScheme(model.style.theme.isDark ? .dark : .light, for: .windowToolbar)
        // The guide goes over the toolbar as well as the page, and swallows the
        // click that dismisses it so the page below does not also turn.
        .overlay { coachOverlay }
        #else
        // Drawn over the page rather than above it, so showing it cannot
        // change the page's size.
        .overlay(alignment: .top) { topBar }
        // The first-run gesture guide sits above even the chrome and swallows
        // the tap that dismisses it, so the page below does not also turn.
        .overlay { coachOverlay }
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

    #if os(macOS)
    /// Every reading action the menu bar posts, as a window toolbar.
    ///
    /// The same set, in the same order the Read menu lists them, so the toolbar
    /// and the menu are two views of one thing rather than two inventories.
    /// Each button calls `perform`, which is what the menu's notification also
    /// reaches.
    @ViewBuilder
    private var macToolbar: some View {
        Button { perform(.contents) } label: { Image(systemName: "list.bullet") }
            .help("Table of Contents (⇧⌘T)")
            .accessibilityLabel("Table of contents")

        Button { perform(.find) } label: { Image(systemName: "magnifyingglass") }
            .help("Find in Book (⌘F)")
            .accessibilityLabel("Find in book")

        Button { perform(.marks) } label: { Image(systemName: "bookmark.square") }
            .help("Marks (⇧⌘B)")
            .accessibilityLabel("Bookmarks and highlights")

        Button { perform(.bookmark) } label: {
            Image(systemName: model.isPageBookmarked ? "bookmark.fill" : "bookmark")
        }
        .help("Add Bookmark (⌘D)")
        .accessibilityLabel(model.isPageBookmarked ? "Remove bookmark" : "Bookmark this page")

        Button { perform(.typography) } label: { Image(systemName: "textformat.size") }
            .help("Text Options (⌥⌘T)")
            .accessibilityLabel("Text options for this book")

        if model.hasNarration {
            Button { perform(.player) } label: { Image(systemName: "waveform") }
                .help("Show Player (⌥⌘P)")
                .accessibilityLabel("Open player")
        }
    }

    /// What each reading command does, in one place.
    private func perform(_ command: ReaderCommand) {
        switch command {
        case .find: showsSearch = true
        case .contents: showsContents = true
        case .marks: showsAnnotations = true
        case .bookmark: model.toggleBookmark()
        case .typography: showsTypography = true
        case .nextPage: Task { await model.nextPage() }
        case .previousPage: Task { await model.previousPage() }
        // Its own window on the Mac, which several open books can share, rather
        // than a sheet belonging to whichever one happened to summon it.
        case .player:
            guard model.hasNarration else { return }
            openWindow(id: "NowPlaying")
        }
    }
    #endif

    /// Opens the full player: a window on the Mac, a sheet everywhere else.
    private func openPlayer() {
        #if os(macOS)
        openWindow(id: "NowPlaying")
        #else
        showsPlayer = true
        #endif
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
        .frame(height: ReaderChrome.barHeight)
        .padding(.top, deviceInsets.top)
        .background {
            // The page's own colour, not a material: the reader's theme is
            // independent of the device appearance, and a system material
            // goes dark over a light page.
            model.style.theme.background.opacity(0.94)
        }
        // The bar, not just its background, reaches the top of the window.
        //
        // Without this the overlay is laid out inside the live safe area and
        // the padding above adds the same inset a second time, so the row sat
        // 59pt too low — floating in the middle of an empty band, with its
        // backdrop washing out the three lines of text behind it. Extending the
        // whole bar makes its position depend on the padding alone: the row
        // occupies exactly `safeAreaTop ..< topReserve`, which is where the page
        // now starts.
        .ignoresSafeArea(edges: .top)
        .opacity(model.chromeVisible ? 1 : 0)
        // Untappable when invisible, so a tap in the top strip turns the page
        // like anywhere else rather than hitting a control that is not there.
        .allowsHitTesting(model.chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: model.chromeVisible)
    }

    #endif

    #if !os(tvOS)
    /// The first-run gesture guide, shown once the page is actually readable —
    /// naming tap zones over a spinner would point at nothing — and only while a
    /// "seen" flag is still unset. Empty the rest of the time, so the overlay it
    /// lives in is inert.
    @ViewBuilder
    private var coachOverlay: some View {
        let showsZones = !hasSeenReaderCoach
        let showsTip = model.hasNarration && !hasSeenNarrationTip
        if model.phase == .ready, showsZones || showsTip {
            ReaderCoachOverlay(
                theme: model.style.theme,
                showsZones: showsZones,
                showsNarrationTip: showsTip,
            ) {
                // Mark seen only what was actually shown, so a plain book's
                // first open does not silently spend the narrated tip a reader
                // has yet to meet.
                if showsZones { hasSeenReaderCoach = true }
                if showsTip { hasSeenNarrationTip = true }
            }
            .transition(.opacity)
        }
    }
    #endif

    @ViewBuilder
    private func pageContent(size: CGSize) -> some View {
        VStack(spacing: 0) {
            // The top bar's reserve, held whether or not the chrome is showing,
            // exactly as the footer holds its own — so toggling can never
            // re-paginate. It stands in for the page's top margin rather than
            // adding to it: 44 points of empty bar is already more breathing
            // room than the margin gave, and stacking both is how the screen
            // ended up spending a fifth of its height before the first word.
            Color.clear.frame(height: ReaderChrome.barHeight)

            PageCanvas(model: model, pageSize: size)
                .padding(.horizontal, model.style.pageMargin)
                .padding(.bottom, model.style.pageMargin)
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
                            // The leading edge belongs to the system's own
                            // dismiss gesture — the reader is presented as a
                            // full-screen cover — so a back-swipe starting
                            // there shuts the book. Unguarded it did that AND
                            // turned the page on the way out.
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
        // Turning the page dismisses a selection left behind on the old one,
        // the way scrolling dismisses a selection anywhere else. But only one
        // left behind: `go(to:)` sets the page and the found text's selection
        // in the same main-actor block, and SwiftUI delivers this change after
        // both — clearing unconditionally wiped the highlight the jump exists
        // to leave. A selection with glyphs on the page just arrived at is the
        // one the reader came to see.
        .onChange(of: model.pageIndex) { model.clearSelectionIfStale() }
        // Also on chapter change: a jump that lands on the same page index (both
        // page 0, say) never fires the pageIndex handler, so a stale selection
        // from the old chapter would otherwise survive at coincidentally
        // matching offsets. `clearSelectionIfStale` keeps a search landing,
        // which re-stamps its selection's chapter.
        .onChange(of: model.chapterIndex) { model.clearSelectionIfStale() }
        #if os(macOS)
        // Bare arrow keys turn pages, which is what a Mac reader tries first.
        // The menu shortcuts are ⌘-arrow so the two do not collide.
        .focusable()
        .focused($pageHasKeyboardFocus)
        // Asynchronous on purpose: a `@FocusState` write from `onAppear` lands
        // inside the transaction that is presenting the page.
        .task { pageHasKeyboardFocus = true }
        .onChange(of: anySheetShowing) { _, showing in
            if !showing { pageHasKeyboardFocus = true }
        }
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
            // The narration rate is seeded earlier, with `downloadHost`.
            applyStyle()
            // Visibility is reported by the screen-level onAppear, not here.
            // `enqueuePosition` and the annotation hooks are installed by
            // `AppModel.reader(for:session:)` and stay installed. They used to
            // be set here and broken again in `onDisappear`, which left
            // `saveProgress` falling through to writing straight to the network
            // — no queue, no position guard — on a path whose ordering against
            // the flush in the other `onDisappear` was never defined.
            //
            // Now Playing is claimed when narration actually starts, not when a
            // narrated book is merely opened: opening one while an audiobook
            // played used to take the lock screen away from it.
        }
        // Land on the page being spoken, if the book carried on while the
        // reader was elsewhere in the app.
        .task { await model.syncToNarration() }
        .task { model.loadAnnotations(await app.annotations(for: model.book.uuid)) }
        #if os(macOS)
        // Menu commands arrive as notifications; only the frontmost reader
        // window is active, so only it responds. Each one routes through
        // `perform`, which is also what the window toolbar calls — one mapping
        // from command to behaviour rather than two that drift.
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.find.notification)) { _ in
            if isActiveScene { perform(.find) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.contents.notification)) { _ in
            if isActiveScene { perform(.contents) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.marks.notification)) { _ in
            if isActiveScene { perform(.marks) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.bookmark.notification)) { _ in
            if isActiveScene { perform(.bookmark) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.typography.notification)) { _ in
            if isActiveScene { perform(.typography) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.nextPage.notification)) { _ in
            if isActiveScene { perform(.nextPage) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.previousPage.notification)) { _ in
            if isActiveScene { perform(.previousPage) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.player.notification)) { _ in
            if isActiveScene { perform(.player) }
        }
        #endif
        // A re-resolve, not an assignment: `model.style = settings.readerStyle`
        // would throw away this book's own settings the moment the reader
        // changed a default, mid-page.
        .onChange(of: settings.readerStyle) { _, _ in applyStyle() }
        // No onDisappear. The model belongs to the app and its closures stay
        // wired, so narration keeps playing and keeps writing its position
        // while the reader browses the library; visibility and release are the
        // screen-level hooks' business, because this view also disappears
        // whenever the phase merely leaves `.ready`.
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
                Text("\(ByteCountText.text(received)) of \(ByteCountText.text(total))")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(model.style.theme.textTertiary)
            } else {
                // No Content-Length: an indeterminate bar is honest, where a
                // bar pinned at zero looks exactly like a stall.
                ProgressView().frame(maxWidth: 280)
                Text(received > 0 ? ByteCountText.text(received) : "Starting…")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(model.style.theme.textTertiary)
            }

            Button("Cancel") { model.cancelDownload() }
                .font(Typography.callout)
                .foregroundStyle(model.style.theme.textSecondary)
        }
        .padding(Metrics.spacing32)
    }

    /// Tap coordinates arrive in the padded frame's space; the layout speaks
    /// in the canvas's, which starts one margin in.
    /// A point in the padded page's coordinates, in the canvas's own.
    ///
    /// Horizontal only: the page keeps its side margins, while its top margin is
    /// now the bar's reserve sitting above it, outside this view entirely.
    private func canvasPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - model.style.pageMargin, y: point.y)
    }

    /// The strip below the page.
    ///
    /// Its `ReaderChrome.barHeight` is reserved whether or not the controls are
    /// showing, so toggling the chrome never changes the page size and never
    /// re-paginates the chapter. What the strip *contains* is conditional; its
    /// height never is.
    private var footer: some View {
        HStack(spacing: Metrics.spacing12) {
            if model.chromeVisible {
                if model.hasNarration {
                    // Toggles narration in place. Build 15 thinned this strip
                    // to the one button and moved skip ±N and the waveform into
                    // the full player behind a swipe — and the phone lost every
                    // visible way to move through the audio. Back as they were.
                    Button {
                        Task { await model.togglePlayback() }
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(model.style.theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.isPlaying ? "Pause narration" : "Play narration")
                    // VoiceOver has no swipe-up, so it reaches the player through
                    // a named action as well as the waveform button.
                    .accessibilityAction(named: "Open player") { openPlayer() }
                    // The full player: the scrubber, the rate and the sleep
                    // timer live only there.
                    //
                    // Not on the Mac, where the toolbar above already carries
                    // it and the footer is meant to stay calm — three targets,
                    // not six.
                    #if !os(macOS)
                    Button {
                        showsPlayer = true
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 17))
                            .foregroundStyle(model.style.theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open player")
                    #endif
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
                // Not on the Mac: the Playback menu carries skip with its own
                // shortcuts, and the panel draws the same two buttons. This is
                // one copy fewer, not a second source of the interval.
                #if !os(macOS)
                if model.hasNarration {
                    // Same seconds, same buttons as the full player and the mini
                    // bar — the setting in Controls & remapping governs all three,
                    // so a reader who tunes it once gets the same jump everywhere.
                    // These are also the only way to move the page *with* the
                    // audio: "follow narration" turns a page back to the spoken
                    // sentence, so a page turned by hand is turned back a few
                    // seconds later, and a listener who wants to go forward has
                    // to take the audio with them.
                    narrationSkipButton(
                        seconds: settings.commandMap.skipBackwardInterval,
                        symbol: "gobackward", action: .skipBackward,
                        label: "Skip back",
                    )
                    narrationSkipButton(
                        seconds: settings.commandMap.skipForwardInterval,
                        symbol: "goforward", action: .skipForward,
                        label: "Skip forward",
                    )
                }
                #endif
                Spacer()
                // Inside the chrome, not beside it: hiding everything should
                // hide everything. It used to stay behind on the grounds that
                // it is what a reader who has cleared the screen still wants —
                // which turned out not to be true of the reader.
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
        }
        .padding(.horizontal, model.style.pageMargin)
        .frame(height: ReaderChrome.barHeight)
        // Swipe up on the strip to open the full player, as well as tapping the
        // waveform. The whole bar is the target: without a content shape an
        // HStack is hittable only where its glyphs are, which made the swipe
        // land perhaps one time in five. The minimum distance keeps it clear
        // of the buttons' taps, and it does nothing on a book with no
        // narration to play. (The mini bar expands on a tap, not a drag —
        // this is the reader's own gesture, not a shared one.)
        //
        // iOS only: this footer is the phone/iPad reader's. tvOS reads through
        // TVReadalongView and drives focus, not drag, and `DragGesture` is not
        // available there at all.
        #if os(iOS)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard model.hasNarration, value.translation.height < -24 else { return }
                    showsPlayer = true
                },
        )
        #endif
    }

    private func narrationSkipButton(
        seconds: TimeInterval, symbol: String, action: PlaybackAction, label: String,
    ) -> some View {
        Button {
            Task {
                await model.readalong?.perform(action, using: settings.commandMap)
                nowPlaying.publish()
            }
        } label: {
            ZStack {
                Image(systemName: symbol).font(.system(size: 17))
                Text("\(Int(seconds))")
                    .font(Typography.sans(8, weight: .semibold))
                    .offset(y: 1)
            }
            .foregroundStyle(model.style.theme.textTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(Int(seconds)) seconds")
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
