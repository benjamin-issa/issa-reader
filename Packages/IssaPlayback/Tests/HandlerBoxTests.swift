import Foundation
import Testing

@testable import IssaPlayback

/// Tearing down one `RemoteCommandCenter` leaves another's handlers alone.
///
/// The commands are the process-wide `MPRemoteCommandCenter.shared()`'s, and the
/// first version of `tearDown` called `removeTarget(nil)` — every target on the
/// command, not this instance's. A transient instance being deallocated stripped
/// a live one's handlers while `isEnabled` stayed set: lit Lock Screen and
/// CarPlay buttons that did nothing. `MPRemoteCommand` cannot list its targets,
/// so a recording stand-in is what makes "exactly its own" observable.
@Suite("Removing remote-command targets")
@MainActor
struct HandlerBoxTests {
    final class RecordingCommand: RemoteCommandTargets {
        var removed: [Any?] = []
        func removeTarget(_ target: Any?) { removed.append(target) }
    }

    @Test("a box removes the tokens it added and no others")
    func removesOnlyItsOwn() {
        let command = RecordingCommand()
        let mine = HandlerBox()
        let theirs = HandlerBox()
        let mineToken = NSObject()
        let theirsToken = NSObject()
        mine.append(command, token: mineToken)
        theirs.append(command, token: theirsToken)

        mine.tearDown()

        #expect(command.removed.count == 1, "one registration, one removal")
        #expect(command.removed.first.flatMap { $0 as? NSObject } === mineToken)
        #expect(!command.removed.contains { $0 == nil }, "removeTarget(nil) strips every instance's handlers")
    }

    @Test("tearing down twice does not remove twice")
    func tearDownIsOneShot() {
        let command = RecordingCommand()
        let box = HandlerBox()
        box.append(command, token: NSObject())
        box.tearDown()
        box.tearDown()
        #expect(command.removed.count == 1)
    }
}
