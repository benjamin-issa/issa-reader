import CoreSpotlight
import IssaCore
import IssaUI
import SwiftUI
import UIKit

@main
@MainActor
struct IssaReaderApp: App {
    /// Only so that `AppServices.start()` runs when the *car* is what launched
    /// the app. There is no other reason for a delegate here.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private let services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services.app)
                .environment(services.settings)
                .environment(services.nowPlaying)
                // Idempotent, and belt-and-braces: the delegate has normally
                // run by now, but a scene that somehow arrives first must not
                // find an unstarted app.
                .task { AppServices.shared.start() }
                // CarPlay's list is kept fresh by `AppServices`, not here: a
                // car-only launch never evaluates this body, so an `.onChange`
                // in it left the shelves empty for the whole drive.
                .tint(Palette.tangerine)
                .onOpenURL { services.app.open($0) }
                // A Spotlight result carries the book's uuid as its identifier,
                // which is the same handle a deep link uses.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
                    else { return }
                    // A search result is browsing, not resuming.
                    services.app.requestBook(id, .details)
                }
                .onContinueUserActivity(BookActivity.type) { activity in
                    guard let id = activity.userInfo?[BookActivity.bookIDKey] as? String else { return }
                    // Handoff carries a reading position; it means carry on.
                    services.app.requestBook(id, .read)
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        content
        #if ISSA_UITEST_FIXTURE
            // Zero-sized and invisible; see `LayoutProbe`.
            .overlay(alignment: .topLeading) { LayoutProbe() }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch app.phase {
            case .launching:
                // Deliberately no content — but painted in the app's own ground
                // so the launch image, this, and the library are one continuous
                // colour. A returning reader never sees the sign-in form flash
                // past on the way to their shelf.
                Palette.paper.ignoresSafeArea()
            case .chooseServer, .signingIn, .expired:
                SignInView()
            case .ready:
                LibraryTabs()
            }
        }
        // The session is restored by `AppServices.start()`, so that a car
        // connecting to a never-foregrounded app finds one.
        .task { await app.watchForExpiry() }
    }
}

/// Library, Reading and Settings.
///
/// Two homes with two jobs: the Library is for looking around, the Reading tab
/// is for getting back to your book. There was once a Listening tab over the
/// same catalogue minus the text-only books, which testers read as two
/// libraries rather than one filtered view; its job is a shelf chip now.
/// (`ListeningView` stays — the macOS sidebar and tvOS still use it.)
struct LibraryTabs: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var libraryPath = NavigationPath()
    @State private var readingPath = NavigationPath()
    /// Opens on Reading: the tab is where you left off, and a launch is
    /// almost always to carry on. Library stays first in the bar.
    @State private var selectedTab = Destination.reading
    @State private var showsPlayer = false

    /// No Playing tab. There used to be one, and the mini player was removed
    /// while it was showing so the same transport was not on screen twice —
    /// but `.tabViewBottomAccessory` is what shapes the bar, so an accessory
    /// that came and went with the selected tab made the tab bar resize on
    /// every switch. Apple's answer to the duplication is not a conditional
    /// accessory; it is not having a full-player tab. The mini bar expands
    /// into a sheet, as it does in Music. The objection was to a tab that
    /// shaped the accessory, not to a third tab: Reading shapes nothing.
    // Named `Destination` rather than `Tab`, which is now SwiftUI's own
    // type in this scope.
    enum Destination: Hashable { case library, reading, settings }

    private func openPendingBook() {
        // Don't tear down the stack when the reader for this very book is already
        // on screen. `navigationDestination` keys on the whole Book value, and a
        // book being read has a moving `position`, so a reset-then-append pushed
        // a *different* value, rebuilt BookDetailView, and dismissed its open
        // fullScreenCover reader mid-session — exactly what a "Currently reading"
        // widget or Handoff deep link to the book you are reading would do. When
        // the reader is closed (or showing a different book) we still reset, so a
        // deep link opens or reopens it and Back lands on the library.
        //
        // Decided before the request is consumed, and the request dropped
        // rather than consumed: consuming arms the one-shot reader request,
        // and one armed for a book already on screen re-presented the reader
        // the next time that book's screen appeared. The reader reports itself
        // visible from the moment its cover is up, so a second link arriving
        // while the book is still opening is caught here too.
        if let pending = app.pendingBook, app.visibleReaderUUID == pending.uuid {
            app.discardPendingBook()
            return
        }
        guard let pending = app.consumePendingBook() else { return }
        // The expanded player is a sheet now, not a tab, so switching tabs no
        // longer moves it out of the way. Left up, it sat over the navigation
        // below while the one-shot reader request was spent behind it — and
        // the reader's own cover cannot present while it is showing.
        showsPlayer = false
        // Presented on whichever book stack is showing. The Reading tab's own
        // Continue card takes this route, and a Continue that flipped the app
        // to the Library tab would be answering a question nobody asked; a
        // widget or Handoff arriving while Settings is up lands on Library; a
        // cold launch runs this with Reading selected, so it lands there.
        if selectedTab == .settings { selectedTab = .library }
        // Pushed either way, so Back from the reader lands on the book and then
        // the tab it came from. `consumePendingBook` has already recorded
        // whether the book's own screen should go straight through to the
        // reader.
        switch selectedTab {
        case .reading:
            readingPath = NavigationPath()
            readingPath.append(pending.book)
        case .library, .settings:
            libraryPath = NavigationPath()
            libraryPath.append(pending.book)
        }
    }

    /// What the Reading tab does when it points at the Library: the flat grid
    /// on a shelf, or, with no shelf, just the tab.
    private func showLibrary(_ shelf: LibraryArrangement.Shelf?) {
        if let shelf { app.showAllBooks(shelf: shelf) }
        selectedTab = .library
    }

    /// The modern `Tab` builder rather than `.tabItem` + `.tag`: the legacy
    /// pair goes through `UITabBarItem` compatibility instead of `UITab`, and
    /// this bar's metrics are the whole point of the change.
    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "books.vertical", value: Destination.library) {
                NavigationStack(path: $libraryPath) {
                    LibraryView()
                        .navigationTitle("Library")
                        .navigationDestination(for: Book.self) { book in
                            BookDetailView(book: book)
                        }
                }
                .background(AccessoryBandReservation(height: reservedBand))
            }

            Tab("Reading", systemImage: "bookmark", value: Destination.reading) {
                NavigationStack(path: $readingPath) {
                    ReadingView(showLibrary: showLibrary)
                        .navigationTitle("Reading")
                        .navigationDestination(for: Book.self) { book in
                            BookDetailView(book: book)
                        }
                }
                .background(AccessoryBandReservation(height: reservedBand))
            }

            Tab("Settings", systemImage: "gearshape", value: Destination.settings) {
                NavigationStack {
                    SettingsView().navigationTitle("Settings")
                }
                .background(AccessoryBandReservation(height: reservedBand))
            }
        }
    }

    /// The tab bar's accessory slot, which is what iOS 26 provides for exactly
    /// this. As a `.safeAreaInset` the mini player was drawn over the floating
    /// tab bar rather than above it, so starting an audiobook hid Library and
    /// Settings entirely.
    ///
    /// It has to be gated on there being something to show. The slot is placed
    /// whether or not its content draws anything, so a `MiniPlayer` that
    /// returned nothing still got a glass capsule at its minimum height, plus
    /// the bottom safe area it reserves — an empty second bar above the tab bar
    /// on every screen, with the library scrolling behind it.
    ///
    /// `isEnabled:` arrived in iOS 26.1 and the deployment target is 26.0, so
    /// the older path applies the modifier conditionally instead. `#available`
    /// is fixed for the life of the process, so the branch it picks never
    /// changes and the 26.1 path never churns view identity; only the fallback
    /// can, and losing the library's scroll position when playback starts is
    /// still better than a bar that is always there and always empty.
    ///
    /// Gated on playback and on nothing else. It briefly also excluded the
    /// Playing tab, which made the accessory — and therefore the bar's whole
    /// shape — a function of the selection, so the tab bar resized on every
    /// switch and the 26.0 branch churned the `TabView`'s identity with it.
    private var showsMiniPlayer: Bool {
        app.playback != nil
    }

    /// The height the accessory adds to the content's bottom safe area on an
    /// iPhone: 139pt with the mini player up against 83pt without, measured
    /// on the iPhone 17 Pro simulator, and the same at the largest
    /// accessibility text size — the bar does not scale with type.
    ///
    /// Reserved while nothing plays, so that starting a book does not shove
    /// every scroll view's bottom edge up by a bar's height and stopping one
    /// does not drop it back. The accessory itself stays gated: the slot
    /// cannot be kept without its glass capsule, so the space is held from the
    /// content's side instead, and the padding here and the accessory below
    /// both follow `playback` in the same update. The idle band is empty
    /// paper, which is the design's chosen trade.
    ///
    /// Phones only. iPad puts its tab bar at the top and floats the accessory
    /// elsewhere, and no iPad simulator was to hand to measure it; there the
    /// content keeps moving with the bar, as it always has.
    private static let accessoryBand: CGFloat = 56

    /// The scheme the app is actually drawing in, read outside the accessory
    /// so it can be handed back to the content inside it.
    @Environment(\.colorScheme) private var colorScheme

    private var reservedBand: CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .phone, !showsMiniPlayer else { return 0 }
        return Self.accessoryBand
    }

    @ViewBuilder
    private var shell: some View {
        if #available(iOS 26.1, *) {
            tabs.tabViewBottomAccessory(isEnabled: showsMiniPlayer) { miniPlayer }
        } else if showsMiniPlayer {
            tabs.tabViewBottomAccessory { miniPlayer }
        } else {
            tabs
        }
    }

    /// Saves the open book and sends the backlog while being suspended.
    ///
    /// Inside a background task, because the point is the network call: without
    /// one the system suspends the process the moment the frame is committed
    /// and the POST never leaves. The expiration handler must end the
    /// assertion, or iOS kills the app for holding it too long.
    private func flushOnSuspend() {
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "issa.flushPosition") {
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
        guard identifier != .invalid else { return }
        Task {
            await app.flushOpenReaders()
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }

    private var miniPlayer: some View {
        MiniPlayer { showsPlayer = true }
            // The palette's colours are trait-adaptive, and inside the tab
            // bar's glass accessory they were resolving against a dark trait
            // while the capsule itself rendered light — so on the Library tab
            // the title came out cream on near-white and all but vanished,
            // while the chapter line under it, a mid-grey either way, stayed
            // legible. Pinning the scheme to the one the rest of the app is
            // drawing in makes the bar read correctly whatever the container
            // decides about its own material.
            .environment(\.colorScheme, colorScheme)
    }

    var body: some View {
        shell
        // Presented from the shell rather than from the accessory: the mini bar
        // is unmounted the moment playback stops, and a sheet owned by it would
        // be torn down mid-gesture.
        .sheet(isPresented: $showsPlayer) { NowPlayingSheet() }
        .onChange(of: app.playback == nil) { _, stopped in
            // Nothing to expand into once the book has stopped.
            if stopped { showsPlayer = false }
        }
        // A link can arrive before the library has loaded, so this waits for
        // the book to exist rather than dropping the request on the floor.
        .onChange(of: app.pendingBook) { openPendingBook() }
        .onChange(of: app.books) { openPendingBook() }
        // Indexed off the main path: a large library should not delay the
        // first frame to make itself searchable.
        .task(id: app.books.count) { await SpotlightIndex.index(app.books) }
        .task { openPendingBook() }
        // An intent runs outside the scene and cannot navigate, so it leaves
        // the book in an inbox for the scene to collect when it appears.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                flushOnSuspend()
                return
            }
            guard phase == .active else { return }
            // A download can finish while the app is in the background, and the
            // finish hook only fires in-process.
            app.refreshDownloadedSet()
            guard let id = AppIntentInbox.shared.bookID else { return }
            AppIntentInbox.shared.bookID = nil
            // "Continue reading" means exactly that.
            app.requestBook(id, .read)
        }
    }
}

/// Holds the mini player's band open in UIKit's safe area.
///
/// SwiftUI's `safeAreaPadding` and `safeAreaInset` on the tab's content draw
/// their band and change nothing: the tab's whole hierarchy is hosted by one
/// UIKit controller (`TabHostingController`, a child of the tab bar
/// controller — there is no `UINavigationController` under a `NavigationStack`
/// on iOS 26), and its scroll views take their insets from UIKit's safe area,
/// which is also where the accessory subtracts its own height. So the
/// reservation goes in the same place — `additionalSafeAreaInsets` on that
/// hosting controller, which every screen in the stack inherits, including a
/// detail screen reached from a rail rather than the path. Sits in each stack's
/// root as a background: a zero-size child controller that sets the inset on
/// its parent, and clears it when the band closes because the accessory has
/// opened.
///
/// The change is animated to the accessory's own duration, so the band handing
/// over to the bar reads as one movement rather than a drop and a rise.
private struct AccessoryBandReservation: UIViewControllerRepresentable {
    let height: CGFloat

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.height = height
        controller.apply(animated: true)
    }

    final class Controller: UIViewController {
        var height: CGFloat = 0
        private var applied: CGFloat?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply(animated: false)
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply(animated: false)
        }

        func apply(animated: Bool) {
            guard let host = parent, applied != height else { return }
            applied = height
            let change = { host.additionalSafeAreaInsets.bottom = self.height }
            if animated, let container = host.view {
                UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut]) {
                    change()
                    container.layoutIfNeeded()
                }
            } else {
                change()
            }
        }
    }
}
