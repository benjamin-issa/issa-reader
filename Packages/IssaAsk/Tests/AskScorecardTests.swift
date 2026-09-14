#if canImport(FoundationModels) && !os(tvOS)
import Foundation
import Testing

@testable import IssaAsk

/// The regression questions, asked repeatedly and recorded rather than asserted.
///
/// Apple's guidance for a new model version is to record what the shipped
/// prompt produces, change the prompt, and compare — and the comparison has to
/// be over more than one run, because the model is not deterministic across
/// versions even when it is within one. This writes one JSON line per run to a
/// file named by `ISSA_ASK_SCORECARD`, which is also the switch: without it the
/// suite is skipped, because fifteen questions five times over is ten minutes a
/// developer did not ask for by typing `swift test`.
///
///     ISSA_ASK_SCORECARD=v1 swift test --filter AskScorecardTests
///
/// `ISSA_ASK_SCORECARD_RUNS` (default 5) and `ISSA_ASK_SCORECARD_DIR` (default
/// the temporary directory) are the other two knobs. The file is the artefact;
/// the test itself only fails if a question cannot be asked at all.
@Suite(.enabled(if: SystemAnswerModel.isAvailableForTesting && AskScorecard.label != nil))
struct AskScorecardTests {
    @Test("every fixture question, several times, on the record")
    func scoreEveryFixtureQuestion() async throws {
        let label = try #require(AskScorecard.label)
        let url = AskScorecard.directory.appending(path: "ask-scorecard-\(label).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var passed = 0, total = 0
        for (book, questions) in AskQuestionFixture.books() {
            let run = try await RegressionRun(book: book)
            defer { run.tearDown() }
            for fixture in try AskQuestionFixture.all(questions) {
                for index in 1...AskScorecard.runs {
                    let outcome = try await run.ask(fixture)
                    var line = try JSONSerialization.jsonObject(
                        with: encoder.encode(outcome)) as! [String: Any]
                    line["label"] = label
                    line["run"] = index
                    line["passes"] = outcome.passes
                    let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
                    try handle.write(contentsOf: data + Data("\n".utf8))
                    total += 1
                    if outcome.passes { passed += 1 }
                }
            }
        }
        print("[scorecard] \(label): \(passed)/\(total) passed — \(url.path)")
    }
}

enum AskScorecard {
    static var label: String? {
        let value = ProcessInfo.processInfo.environment["ISSA_ASK_SCORECARD"] ?? ""
        return value.isEmpty ? nil : value
    }

    static var runs: Int {
        max(1, Int(ProcessInfo.processInfo.environment["ISSA_ASK_SCORECARD_RUNS"] ?? "") ?? 5)
    }

    static var directory: URL {
        ProcessInfo.processInfo.environment["ISSA_ASK_SCORECARD_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
    }
}
#endif
