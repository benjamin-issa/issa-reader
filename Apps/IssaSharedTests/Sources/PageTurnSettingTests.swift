import Foundation
import IssaRender
import Testing

@testable import IssaReader_iOS

/// The Page turn choice: Slide unless the reader picked otherwise, kept across
/// launches, and costing the open book nothing when it changes.
@Suite("The page turn setting")
@MainActor
struct PageTurnSettingTests {
    private func withSuite(_ body: (String) -> Void) {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        body(suite)
    }

    /// And nothing is written for them: moving the default later moves
    /// everyone who never chose, as `progressScope`'s does.
    @Test("a reader who never chose gets Slide, and nothing is stored for them")
    func slideByDefault() {
        withSuite { suite in
            #expect(PlaybackSettings(suiteName: suite).pageTurn == .slide)
            #expect(UserDefaults(suiteName: suite)?.object(forKey: "issa.pageTurn") == nil)
        }
    }

    /// A value this build does not know — written by a later one, say — is no
    /// reason to turn the animation off.
    @Test("a stored value this build cannot read is Slide too")
    func unknownIsSlide() {
        withSuite { suite in
            UserDefaults(suiteName: suite)?.set("curl", forKey: "issa.pageTurn")
            #expect(PlaybackSettings(suiteName: suite).pageTurn == .slide)
        }
    }

    @Test("the choice is the choice a relaunch restores", arguments: PageTurnStyle.allCases)
    func persists(style: PageTurnStyle) {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            settings.pageTurn = style
            #expect(PlaybackSettings(suiteName: suite).pageTurn == style)
        }
    }

    /// Kept out of the reading style on purpose: a change there re-paginates
    /// the open book.
    @Test("changing it leaves the reading style alone")
    func notAStyle() {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            let style = settings.readerStyle
            settings.pageTurn = .cover
            #expect(settings.readerStyle == style)
            #expect(PlaybackSettings(suiteName: suite).readerStyle == style)
        }
    }
}
