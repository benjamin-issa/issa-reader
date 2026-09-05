import CarPlay
import Foundation
import Testing

@testable import IssaReader_iOS

/// What may be a tab, and how many.
///
/// This suite exists because of a crash, not a hypothesis. Build 24 put
/// `CPNowPlayingTemplate.shared` in the root tab bar, and
/// `-[CPTabBarTemplate validateTemplates:]` threw over it: five identical
/// `SIGABRT`s on the device, one per time the car connected, from inside
/// `initWithTemplates:` — before `setRootTemplate` was ever reached, so no
/// completion handler could have caught it and no `do`/`catch` can, because it
/// is an Objective-C exception. The only defence against a constructor that
/// validates by throwing is to never hand it a bad argument, and
/// `tabs(from:limit:)` is where that is decided.
///
/// `@MainActor` because CarPlay's templates are `CARPLAY_TEMPLATE_UI_ACTOR`.
@Suite("Choosing the CarPlay tab bar's tabs")
@MainActor
struct CarPlayRootTemplateTests {
    private func list(_ title: String) -> CPListTemplate {
        CPListTemplate(title: title, sections: [])
    }

    @Test("list templates are tabs")
    func listsAreKept() {
        let templates = [list("Recent"), list("Library"), list("Downloaded")]
        let chosen = CarPlaySceneDelegate.tabs(from: templates, limit: 5)
        #expect(chosen.count == 3)
        #expect(zip(chosen, templates).allSatisfy { $0 === $1 })
    }

    /// The regression itself. Reverting `tabs(from:limit:)` to pass its input
    /// through fails here, and crashes the app in a car.
    @Test("the now playing template is not, because the tab bar aborts over it")
    func nowPlayingIsExcluded() {
        let chosen = CarPlaySceneDelegate.tabs(
            from: [list("Recent"), CPNowPlayingTemplate.shared], limit: 5)
        #expect(chosen.count == 1)
        #expect(!chosen.contains { $0 === CPNowPlayingTemplate.shared })
    }

    /// `maximumTabCount` varies with the app's entitlements — the header says
    /// so — and the system throws over an array longer than it, exactly as it
    /// throws over a member it will not accept. Both halves of the guard, or
    /// neither.
    @Test("no more tabs than the system allows", arguments: [1, 2, 3])
    func clampsToTheLimit(_ limit: Int) {
        let chosen = CarPlaySceneDelegate.tabs(
            from: [list("a"), list("b"), list("c"), list("d")], limit: limit)
        #expect(chosen.count == limit)
    }

    /// A limit of zero is not a crash and not an empty tab bar: `makeRootTemplate`
    /// falls back to a single list as the root, which is a usable car screen.
    @Test("a limit of nothing yields nothing rather than an empty tab bar")
    func zeroLimit() {
        #expect(CarPlaySceneDelegate.tabs(from: [list("a")], limit: 0).isEmpty)
    }

    /// Stated as an allow-list, so a template type added later has to be shown
    /// to be legal rather than merely fail to be recognised as illegal.
    @Test("an unknown template type is not admitted on the strength of not being now playing")
    func unknownTypesAreRefused() {
        let alert = CPAlertTemplate(titleVariants: ["x"], actions: [])
        let chosen = CarPlaySceneDelegate.tabs(from: [list("a"), alert], limit: 5)
        #expect(chosen.count == 1)
        #expect(chosen.first === chosen.first as? CPListTemplate)
    }
}
