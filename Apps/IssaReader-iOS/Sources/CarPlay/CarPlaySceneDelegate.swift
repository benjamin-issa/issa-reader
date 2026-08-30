import CarPlay
import IssaCore
import IssaPlayback
import UIKit

/// The CarPlay scene.
///
/// CarPlay audio apps do not draw their own UI; the system renders a fixed set
/// of templates and the app supplies their contents. So the design work here is
/// what fills those templates and how the hardware maps — which is why control
/// remapping lives in the shared model rather than in this file.
///
/// This compiles and runs in the CarPlay Simulator today. It will not activate
/// in a real vehicle until Apple grants the
/// `com.apple.developer.carplay-audio` entitlement, which is requested
/// separately and tied to App Store distribution.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
    ) {
        self.interfaceController = interfaceController
        CarPlayBridge.shared.surfaceDidConnect()
        interfaceController.setRootTemplate(makeRootTemplate(), animated: false, completion: nil)
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController,
    ) {
        self.interfaceController = nil
        CarPlayBridge.shared.surfaceDidDisconnect()
    }

    private func makeRootTemplate() -> CPTemplate {
        let library = CPListTemplate(title: "Library", sections: [librarySection()])
        library.tabTitle = "Library"
        library.tabImage = UIImage(systemName: "books.vertical")

        let recent = CPListTemplate(title: "Recent", sections: [continueSection()])
        recent.tabTitle = "Recent"
        recent.tabImage = UIImage(systemName: "clock")

        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.tabTitle = "Now"
        nowPlaying.tabImage = UIImage(systemName: "play.circle")
        // The rate button is the control drivers reach for most; the system
        // draws transport, so this is the one worth adding.
        nowPlaying.updateNowPlayingButtons([
            CPNowPlayingPlaybackRateButton { _ in CarPlayBridge.shared.cycleRate() },
        ])

        return CPTabBarTemplate(templates: [library, nowPlaying, recent])
    }

    private func librarySection() -> CPListSection {
        CPListSection(items: CarPlayBridge.shared.libraryItems().map(makeItem))
    }

    private func continueSection() -> CPListSection {
        CPListSection(items: CarPlayBridge.shared.continueItems().map(makeItem))
    }

    private func makeItem(_ entry: CarPlayBridge.Entry) -> CPListItem {
        let item = CPListItem(text: entry.title, detailText: entry.subtitle)
        item.handler = { _, completion in
            CarPlayBridge.shared.play(bookID: entry.bookID)
            completion()
        }
        if let progress = entry.progress {
            item.playbackProgress = CGFloat(progress)
        }
        return item
    }
}
