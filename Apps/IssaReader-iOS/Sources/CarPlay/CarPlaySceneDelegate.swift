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
        interfaceController.setRootTemplate(makeRootTemplate(), animated: false, completion: nil)
        // Updating sections in place rather than rebuilding the root: replacing
        // the root template in a moving car dumps the driver back to the first
        // tab, which is exactly the wrong moment for that.
        CarPlayBridge.shared.onLibraryChange = { [weak self] in self?.refreshLists() }
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
    }

    private func refreshLists() {
        for (shelf, template) in lists {
            template.updateSections([section(for: shelf)])
        }
    }

    private func makeRootTemplate() -> CPTemplate {
        var templates: [CPTemplate] = []
        for shelf in CarPlayCatalogue.Shelf.allCases {
            let list = CPListTemplate(title: shelf.title, sections: [section(for: shelf)])
            list.tabTitle = shelf.title
            list.tabImage = UIImage(systemName: shelf.symbol)
            // A blank list in a car is indistinguishable from an app that has
            // crashed, so every shelf says why it is empty.
            list.emptyViewTitleVariants = [shelf.emptyMessage]
            lists[shelf] = list
            templates.append(list)
        }

        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.tabTitle = "Now"
        nowPlaying.tabImage = UIImage(systemName: "play.circle")
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
        templates.append(nowPlaying)

        return CPTabBarTemplate(templates: Array(templates.prefix(CPTabBarTemplate.maximumTabCount)))
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
                if let message = await CarPlayBridge.shared.play(bookID: entry.bookUUID) {
                    self?.presentError(message)
                } else {
                    self?.interfaceController?.pushTemplate(
                        CPNowPlayingTemplate.shared, animated: true, completion: nil)
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
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            }],
        )
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }
}

// `@preconcurrency`: the observer protocol carries no actor annotation, but
// CarPlay calls it from the same main-thread UI context as everything else in
// this file.
extension CarPlaySceneDelegate: @preconcurrency CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        let titles = CarPlayBridge.shared.chapters?() ?? []
        guard !titles.isEmpty else { return }
        let current = CarPlayBridge.shared.currentChapter?()
        let items = titles.prefix(itemLimit).enumerated().map { index, title -> CPListItem in
            let item = CPListItem(text: title, detailText: nil)
            item.isPlaying = index == current
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    await CarPlayBridge.shared.onPlayChapter?(index)
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                    completion()
                }
            }
            return item
        }
        let list = CPListTemplate(title: "Chapters", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }
}
