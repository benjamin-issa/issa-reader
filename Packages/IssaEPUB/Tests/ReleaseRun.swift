import Foundation
import Testing

/// The release switch: `ISSA_RELEASE_RUN=1` turns a suite's missing input
/// from a skip into a failure.
///
/// The real-alignment suites read EPUBs the servers aligned, which are too big
/// to commit, and skip when they are absent so an ordinary checkout stays
/// green. But a skip prints one line among hundreds and exits 0, and a release
/// is meant to see these suites *run* — they are the only coverage of what the
/// servers really write. With the switch on, a test that would have skipped
/// runs and records an issue naming each absent file instead, so the release
/// run goes red. Without it nothing changes.
enum ReleaseRun {
    static var isOn: Bool { ProcessInfo.processInfo.environment["ISSA_RELEASE_RUN"] == "1" }

    /// For `.enabled(if:)`: run when every input is present, and always on a
    /// release run, where an absent one is `require`'s to report.
    static func shouldRun(needing paths: [String]) -> Bool {
        isOn || paths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    /// Records an issue for every absent path, and says whether all were there.
    ///
    /// The first line of a gated test: `guard ReleaseRun.require([…]) else
    /// { return }`.
    static func require(_ paths: [String], sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
        for path in missing {
            Issue.record(
                "\(path) is absent. A release run (ISSA_RELEASE_RUN=1) must see this suite run, not skip.",
                sourceLocation: sourceLocation)
        }
        return missing.isEmpty
    }
}

@Suite("The release switch")
struct ReleaseRunTests {
    /// The switch's whole promise: an absent input is an issue, not a pass.
    @Test("an absent input is recorded as an issue")
    func absenceIsAnIssue() {
        withKnownIssue {
            #expect(!ReleaseRun.require(["/nonexistent/issa-release-run.epub"]))
        }
    }

    @Test("a present input is not")
    func presenceIsNot() {
        #expect(ReleaseRun.require([NSTemporaryDirectory()]))
        #expect(ReleaseRun.shouldRun(needing: [NSTemporaryDirectory()]))
    }
}
