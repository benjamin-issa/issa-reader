import CarPlay
import IssaCore
import IssaPlayback
import UIKit

/// The CarPlay scene.
///
/// CarPlay audio apps do not draw their own UI; the system renders a fixed set
/// of templates and the app supplies their contents. So the design work here is
/// what fills those templates and how the hardware maps — which is why control
/// remapping lives in the shared model rather than in this file, and why the
/// list rules live in `CarPlayCatalogue`, where they can be tested.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var lists: [CarPlayCatalogue.Shelf: CPListTemplate] = [:]
    /// Covers already fetched, so scrolling a list does not re-download them.
    private var covers: [String: UIImage] = [:]

    /// What the head unit will actually draw. CarPlay enforces these rather
    /// than advising them, and the old bridge handed it fifty rows.
    private var itemLimit: Int { Int(CPListTemplate.maximumItemCount) }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
    ) {
        self.interfaceController = interfaceController
        CarPlayBridge.shared.surfaceDidConnect()
        // Written and *flushed* before the root template is built, because
        // building it is the thing that used to abort the process. Five crash
        // reports arrived with a log that said nothing about CarPlay at all;
        // this is the line that makes the next one diagnosable from the
        // reader's own export. See `IssaLog.flushNow`.
        IssaLog.info("carplay connected", [
            "maximumTabCount": String(CPTabBarTemplate.maximumTabCount),
            "maximumItemCount": String(CPListTemplate.maximumItemCount),
        ])
        IssaLog.flushNow()

        let root = makeRootTemplate()
        interfaceController.setRootTemplate(root, animated: false) { ok, error in
            // Never `nil`. `CPInterfaceController.h` states that a presentation
            // which fails *without* a completion block throws — so passing nil
            // makes every rejection a process kill rather than a bad screen.
            guard !ok else {
                IssaLog.info("carplay root template set", ["template": Self.name(of: root)])
                return
            }
            IssaLog.failure(
                "carplay root template", error ?? StorytellerError.notFound,
                ["template": Self.name(of: root)])
        }
        // Updating sections in place rather than rebuilding the root: replacing
        // the root template in a moving car dumps the driver back to the first
        // tab, which is exactly the wrong moment for that.
        CarPlayBridge.shared.onLibraryChange = { [weak self] in self?.refreshLists() }
    }

    /// The class name, for a log line. `String(describing:)` on a CarPlay
    /// template prints its whole description including a fresh identifier,
    /// which makes two lines about the same template look different.
    private static func name(of template: CPTemplate) -> String {
        String(describing: type(of: template))
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController,
    ) {
        self.interfaceController = nil
        CarPlayBridge.shared.onLibraryChange = nil
        CPNowPlayingTemplate.shared.remove(self)
        lists.removeAll()
        covers.removeAll()
        CarPlayBridge.shared.surfaceDidDisconnect()
        IssaLog.info("carplay disconnected")
    }

    private func refreshLists() {
        for (shelf, template) in lists {
            template.updateSections([section(for: shelf)])
        }
    }

    private func makeRootTemplate() -> CPTemplate {
        var shelves: [CPListTemplate] = []
        for shelf in CarPlayCatalogue.Shelf.allCases {
            let list = CPListTemplate(title: shelf.title, sections: [section(for: shelf)])
            list.tabTitle = shelf.title
            list.tabImage = UIImage(systemName: shelf.symbol)
            // A blank list in a car is indistinguishable from an app that has
            // crashed, so every shelf says why it is empty.
            list.emptyViewTitleVariants = [shelf.emptyMessage]
            lists[shelf] = list
            shelves.append(list)
        }
        configureNowPlaying()

        // Filtered and clamped *before* the tab bar is constructed, because
        // `CPTabBarTemplate.init(templates:)` validates its argument by
        // throwing an Objective-C exception — which Swift cannot catch. There
        // is no recovering from a bad array; there is only not building one.
        let chosen = Self.tabs(from: shelves, limit: CPTabBarTemplate.maximumTabCount)
        IssaLog.info("carplay tabs", [
            "chosen": chosen.map(Self.name(of:)).joined(separator: ","),
            "offered": String(shelves.count),
        ])
        // A tab bar needs something to hold, and one tab is a tab bar drawn
        // around a single list for no reason.
        guard chosen.count > 1 else {
            return chosen.first ?? shelves.first
                ?? CPListTemplate(title: "Library", sections: [])
        }
        return CPTabBarTemplate(templates: chosen)
    }

    /// The templates that may legally be tabs, at most `limit` of them.
    ///
    /// This function exists because of what it excludes. `CPNowPlayingTemplate`
    /// was a tab here, and `-[CPTabBarTemplate validateTemplates:]` rejects it:
    /// five identical `SIGABRT`s on build 24, one per time the car connected,
    /// thrown from `initWithTemplates:` before `setRootTemplate` was ever
    /// reached. Now Playing is reached by *pushing* it — see `showNowPlaying()`,
    /// whose fallback path was already written for exactly this arrangement.
    ///
    /// `limit` comes from `CPTabBarTemplate.maximumTabCount`, which the header
    /// says varies with the app's entitlements and which the system throws over
    /// as well. Clamping is not belt-and-braces; it is the other half of the
    /// same guard.
    static func tabs(from candidates: [CPTemplate], limit: Int) -> [CPTemplate] {
        guard limit > 0 else { return [] }
        // List and grid, and nothing else. Stated as an allow-list rather than
        // a deny-list: a template type added here later should have to be
        // shown to be legal, not merely fail to be recognised as illegal.
        let legal = candidates.filter { $0 is CPListTemplate || $0 is CPGridTemplate }
        return Array(legal.prefix(limit))
    }

    /// Everything the Now Playing screen needs, whether or not it is on screen.
    ///
    /// Configured at connect time and never as a tab: the observer and the
    /// buttons have to be in place before the driver reaches the screen, and
    /// pushing an unconfigured shared template is how Up Next comes up empty.
    private func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        // The rate button is the control drivers reach for most; the system
        // draws transport, so this is the one worth adding.
        nowPlaying.updateNowPlayingButtons([
            CPNowPlayingPlaybackRateButton { _ in CarPlayBridge.shared.cycleRate() },
        ])
        // Chapters, reached the way CarPlay expects them to be — from Up Next
        // on the Now Playing screen rather than by drilling through the library,
        // which would mean fetching a manifest for a book nobody has started.
        nowPlaying.upNextTitle = "Chapters"
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.add(self)
    }

    /// Brings the Now Playing screen up.
    ///
    /// A push, which is how an audio app is meant to reach it. It was briefly a
    /// tab instead, on the reasoning that one shared instance cannot be in two
    /// places — true, but the conclusion was backwards: the tab bar will not
    /// accept it at all, and said so by aborting the process. See `tabs(from:limit:)`.
    ///
    /// Reports the failure rather than passing `nil`, because a control that
    /// silently does nothing is the worst outcome available here — and because
    /// a `nil` completion turns a refused push into a crash at the wheel.
    private func showNowPlaying() {
        guard let controller = interfaceController else { return }
        // Already there. Pushing a template that is on top of the stack is
        // refused, and the refusal would be logged as though something had
        // gone wrong — a driver tapping a second row while Now Playing is up
        // is the ordinary case, not a fault.
        guard controller.topTemplate !== CPNowPlayingTemplate.shared else { return }
        controller.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { ok, error in
            guard !ok else { return }
            IssaLog.failure(
                "carplay now playing", error ?? StorytellerError.notFound, [:])
        }
    }

    private func section(for shelf: CarPlayCatalogue.Shelf) -> CPListSection {
        let playing = CarPlayBridge.shared.playingBookUUID?()
        return CPListSection(
            items: CarPlayBridge.shared.entries(for: shelf, limit: itemLimit).map {
                makeItem($0, isPlaying: $0.bookUUID == playing)
            },
        )
    }

    private func makeItem(_ entry: CarPlayCatalogue.Entry, isPlaying: Bool) -> CPListItem {
        let item = CPListItem(text: entry.title, detailText: entry.subtitle)
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                IssaLog.info("carplay row tapped", ["book": entry.bookUUID])
                if let message = await CarPlayBridge.shared.play(bookID: entry.bookUUID) {
                    IssaLog.error("carplay could not play", [
                        "book": entry.bookUUID, "reason": message,
                    ])
                    self?.presentError(message)
                } else {
                    // The driver tapped a row and must see the screen change.
                    // An earlier version pushed with `completion: nil` and
                    // threw the rejection away, so audio started and the screen
                    // did not move — which this file's own comment calls
                    // indistinguishable from a crash at the wheel.
                    self?.showNowPlaying()
                }
                completion()
            }
        }
        if let progress = entry.progress {
            item.playbackProgress = CGFloat(progress)
        }
        item.isPlaying = isPlaying
        applyCover(to: item, bookUUID: entry.bookUUID)
        return item
    }

    /// Covers arrive after the row does.
    ///
    /// `CPListItem` is mutable once shown, which is what makes this safe:
    /// waiting for every cover before drawing the list would leave a driver
    /// looking at nothing while the phone talks to the server.
    private func applyCover(to item: CPListItem, bookUUID: String) {
        if let cached = covers[bookUUID] {
            item.setImage(cached)
            return
        }
        Task { @MainActor [weak self, weak item] in
            guard let data = await CarPlayBridge.shared.cover?(bookUUID),
                  let image = UIImage(data: data) else { return }
            self?.covers[bookUUID] = image
            item?.setImage(image)
        }
    }

    private func presentError(_ message: String) {
        let alert = CPAlertTemplate(
            titleVariants: [message],
            actions: [CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.interfaceController?.dismissTemplate(animated: true) { ok, error in
                    guard !ok else { return }
                    IssaLog.failure(
                        "carplay dismiss alert", error ?? StorytellerError.notFound, [:])
                }
            }],
        )
        interfaceController?.presentTemplate(alert, animated: true) { ok, error in
            // If even the error alert cannot be shown, the message still has to
            // land somewhere — and a `nil` completion here would have turned
            // "could not start that book" into a crash.
            guard !ok else { return }
            IssaLog.failure(
                "carplay present alert", error ?? StorytellerError.notFound,
                ["message": message])
        }
    }
}

// `@preconcurrency`: the observer protocol carries no actor annotation, but
// CarPlay calls it from the same main-thread UI context as everything else in
// this file.
extension CarPlaySceneDelegate: @preconcurrency CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        let titles = CarPlayBridge.shared.chapters?() ?? []
        guard !titles.isEmpty else {
            IssaLog.warning("carplay up next was empty")
            return
        }
        let current = CarPlayBridge.shared.currentChapter?()
        let items = titles.prefix(itemLimit).enumerated().map { index, title -> CPListItem in
            let item = CPListItem(text: title, detailText: nil)
            item.isPlaying = index == current
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    IssaLog.info("carplay chapter tapped", ["index": String(index)])
                    await CarPlayBridge.shared.onPlayChapter?(index)
                    self?.interfaceController?.popTemplate(animated: true) { ok, error in
                        guard !ok else { return }
                        IssaLog.failure(
                            "carplay pop chapters", error ?? StorytellerError.notFound, [:])
                    }
                    completion()
                }
            }
            return item
        }
        let list = CPListTemplate(title: "Chapters", sections: [CPListSection(items: items)])
        // A `CPListTemplate` is the one thing an audio app may push on top of
        // Now Playing, which is why this is a list and not a grid.
        interfaceController?.pushTemplate(list, animated: true) { ok, error in
            guard !ok else { return }
            IssaLog.failure(
                "carplay push chapters", error ?? StorytellerError.notFound,
                ["chapters": String(items.count)])
        }
    }
}
