import Foundation
import Testing

@testable import IssaAsk

/// The release switch: `ISSA_RELEASE_RUN=1` turns a real-model suite's skip
/// into a failure.
///
/// The same switch, and the same shape, as `IssaEPUBTests`' `ReleaseRun`, for
/// the other kind of input a suite can be missing. `RegressionQuestionsTests`
/// and `SystemAnswerModelTests` need Apple's on-device model, and skip without
/// it so an ordinary machine stays green. But a skip prints one line among
/// hundreds and exits 0 — Apple Intelligence switched off, or the model still
/// downloading, and `swift test --filter IssaAskTests` passes having asked the
/// real model nothing — and a release is meant to see these suites *run*: they
/// are the only check that the excerpts retrieval chooses are enough for the
/// model to answer from. With the switch on, a test that would have skipped
/// runs and records an issue saying the model is missing, so the release run
/// goes red. Without it nothing changes.
enum ReleaseRun {
    static var isOn: Bool { isOn(ProcessInfo.processInfo.environment) }

    static func isOn(_ environment: [String: String]) -> Bool {
        environment["ISSA_RELEASE_RUN"] == "1"
    }

    #if canImport(FoundationModels) && !os(tvOS)
    /// For `.enabled(if:)`: run when the model is available, and always on a
    /// release run, where its absence is `requireModel`'s to report.
    static var shouldRunModelSuites: Bool {
        shouldRun(releaseRun: isOn, modelAvailable: SystemAnswerModel.isAvailableForTesting)
    }

    /// The first line of a gated test: `guard ReleaseRun.requireModel() else
    /// { return }`. Records an issue when the model is missing, and says
    /// whether it is there.
    static func requireModel(sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        require(modelAvailable: SystemAnswerModel.isAvailableForTesting,
                sourceLocation: sourceLocation)
    }
    #endif

    static func shouldRun(releaseRun: Bool, modelAvailable: Bool) -> Bool {
        releaseRun || modelAvailable
    }

    static func require(
        modelAvailable: Bool, sourceLocation: SourceLocation = #_sourceLocation,
    ) -> Bool {
        guard !modelAvailable else { return true }
        Issue.record(
            """
            Apple's on-device model is not available (Apple Intelligence off, or the model \
            still downloading). A release run (ISSA_RELEASE_RUN=1) must see this suite run, \
            not skip.
            """,
            sourceLocation: sourceLocation)
        return false
    }
}

@Suite("The release switch, for the real-model suites")
struct ReleaseRunTests {
    /// The switch's whole promise: a missing model is an issue, not a pass.
    @Test("a missing model is recorded as an issue")
    func absenceIsAnIssue() {
        withKnownIssue {
            #expect(!ReleaseRun.require(modelAvailable: false))
        }
    }

    @Test("a present model is not")
    func presenceIsNot() {
        #expect(ReleaseRun.require(modelAvailable: true))
    }

    /// With the switch on, the suites run whatever the model says — which is
    /// what lets `requireModel` report its absence instead of a skip hiding it.
    @Test("the switch makes a model suite run, and nothing else does")
    func switchDecidesTheGate() {
        #expect(ReleaseRun.shouldRun(releaseRun: true, modelAvailable: false))
        #expect(ReleaseRun.shouldRun(releaseRun: false, modelAvailable: true))
        #expect(!ReleaseRun.shouldRun(releaseRun: false, modelAvailable: false))
        #expect(ReleaseRun.isOn(["ISSA_RELEASE_RUN": "1"]))
        #expect(!ReleaseRun.isOn(["ISSA_RELEASE_RUN": "0"]))
        #expect(!ReleaseRun.isOn([:]))
    }
}
