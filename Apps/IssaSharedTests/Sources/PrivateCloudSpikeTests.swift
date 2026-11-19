#if canImport(FoundationModels)
import Foundation
import FoundationModels
import IssaAsk
import Testing

/// What Apple's Private Cloud Compute model actually does from inside this app.
///
/// Opt-in, and never part of a release run: it asks a real server and spends
/// the device's daily allowance. Set `ISSA_PCC_SPIKE=1` in the test run (a copy
/// of the `.xctestrun`, as the layout sweep does) to run it, and
/// `ISSA_PCC_SPIKE_ASKS` (default 3, at most 20) to choose how many ordinary
/// asks it makes.
///
/// It answers the questions the rest of the work depends on: whether the model
/// is reachable from a simulator (or only from a device), how big its window
/// is, how quickly the allowance runs down, and whether it refuses a violent
/// passage that the on-device model, with permissive guardrails, would answer.
/// Every passage here is public domain (Alice, Gutenberg #11) or invented.
@Suite(
    "Private Cloud Compute spike",
    .enabled(if: ProcessInfo.processInfo.environment["ISSA_PCC_SPIKE"] != nil),
)
struct PrivateCloudSpikeTests {
    static let alice = """
        [1] (Section 2) Alice was beginning to get very tired of sitting by her sister on the bank, and of having \
        nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures \
        or conversations in it.

        [2] (Section 2) There was nothing so very remarkable in that; nor did Alice think it so very much out of \
        the way to hear the Rabbit say to itself, "Oh dear! Oh dear! I shall be late!" … when the Rabbit actually \
        took a watch out of its waistcoat-pocket, and looked at it, and then hurried on, Alice started to her feet.
        """

    /// Invented for this test: a short, deliberately violent scene, of the kind
    /// any thriller has on every other page.
    static let violent = """
        [1] (Section 9) The ferryman drove the knife twice into Oswin's side and held him under the black water \
        until the struggling stopped. Then he wiped the blade on the dead man's coat and rowed back alone.

        [2] (Section 9) By morning the village knew only that Oswin had not come home, and that the ferryman's \
        boat was dry.
        """

    @Test("availability, window, quota, and a handful of real asks")
    func spike() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else {
            print("[pcc-spike] OS below 27: PrivateCloudComputeLanguageModel unavailable")
            return
        }
        let model = PrivateCloudComputeLanguageModel()
        print("[pcc-spike] availability=\(model.availability) isAvailable=\(model.isAvailable)")
        Self.printQuota(model, label: "start")
        do {
            let size = try await model.contextSize
            print("[pcc-spike] contextSize=\(size)")
        } catch {
            print("[pcc-spike] contextSize threw: \(String(reflecting: error))")
        }
        print("[pcc-spike] capabilities=\(model.capabilities)")
        guard model.isAvailable else { return }

        if ProcessInfo.processInfo.environment["ISSA_PCC_SPIKE"] == "probe" {
            await Self.probe(model)
            return
        }

        let asks = min(20, max(1, Int(ProcessInfo.processInfo.environment["ISSA_PCC_SPIKE_ASKS"] ?? "") ?? 3))
        for index in 1...asks {
            await Self.ask(
                model, label: "alice-\(index)",
                excerpts: Self.alice, question: "What did the Rabbit take out of its pocket?")
            Self.printQuota(model, label: "after alice-\(index)")
        }
        await Self.ask(
            model, label: "violent", excerpts: Self.violent, question: "What happened to Oswin?")
        Self.printQuota(model, label: "after violent")
        await Self.ask(
            model, label: "reasoning-light", excerpts: Self.alice,
            question: "Why did Alice start to her feet?", reasoning: .light)
        Self.printQuota(model, label: "end")
    }

    @available(iOS 27.0, macOS 27.0, *)
    static func ask(
        _ model: PrivateCloudComputeLanguageModel, label: String,
        excerpts: String, question: String,
        reasoning: ContextOptions.ReasoningLevel? = nil,
    ) async {
        let session = LanguageModelSession(model: model, instructions: AskPromptBuilder.instructions)
        let prompt = AskPromptBuilder.frame(question: question, excerpts: excerpts)
        let started = Date()
        var firstWord: TimeInterval?
        var text = ""
        do {
            let stream = session.streamResponse(
                to: prompt,
                options: GenerationOptions(temperature: 0, maximumResponseTokens: 250),
                contextOptions: ContextOptions(reasoningLevel: reasoning))
            for try await snapshot in stream {
                if firstWord == nil, !snapshot.content.isEmpty { firstWord = Date().timeIntervalSince(started) }
                text = snapshot.content
            }
            let usage = session.usage
            print("[pcc-spike] \(label) ok ms=\(Int(Date().timeIntervalSince(started) * 1000)) "
                + "ttfw=\(Int((firstWord ?? -1) * 1000)) "
                + "in=\(usage.input.totalTokenCount) out=\(usage.output.totalTokenCount) "
                + "reasoning=\(usage.output.reasoningTokenCount)")
            print("[pcc-spike] \(label) answer: \(text.replacingOccurrences(of: "\n", with: " ⏎ "))")
        } catch {
            print("[pcc-spike] \(label) threw after \(Int(Date().timeIntervalSince(started) * 1000)) ms: "
                + String(reflecting: error))
        }
    }

    /// The smallest requests there are, each given 90 seconds: whether *any*
    /// request from this app is answered, before blaming anything in ours.
    @available(iOS 27.0, macOS 27.0, *)
    static func probe(_ model: PrivateCloudComputeLanguageModel) async {
        struct Probe: Sendable { let label: String; let run: @Sendable () async throws -> String }
        let probes = [
            Probe(label: "respond, no instructions") {
                try await LanguageModelSession(model: model).respond(to: "Say hello in three words.").content
            },
            Probe(label: "stream, no instructions") {
                var last = ""
                for try await s in LanguageModelSession(model: model).streamResponse(to: "Say hello in three words.") {
                    last = s.content
                }
                return last
            },
            Probe(label: "respond, Ask instructions, greedy") {
                try await LanguageModelSession(model: model, instructions: AskPromptBuilder.instructions).respond(
                    to: AskPromptBuilder.frame(question: "What did the Rabbit take out of its pocket?", excerpts: alice),
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 200)).content
            },
        ]
        for probe in probes {
            let started = Date()
            let result = await withTaskGroup(of: String.self) { group in
                group.addTask {
                    do { return "ok: " + (try await probe.run()).replacingOccurrences(of: "\n", with: " ⏎ ") }
                    catch { return "threw: " + String(reflecting: error) }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(90))
                    return "no answer within 90 s"
                }
                let first = await group.next() ?? "nothing"
                group.cancelAll()
                return first
            }
            print("[pcc-spike] probe '\(probe.label)' after \(Int(Date().timeIntervalSince(started))) s — \(result)")
            printQuota(model, label: "after \(probe.label)")
        }
    }

    @available(iOS 27.0, macOS 27.0, *)
    static func printQuota(_ model: PrivateCloudComputeLanguageModel, label: String) {
        let usage = model.quotaUsage
        let state: String
        switch usage.status {
        case .belowLimit(let below): state = "belowLimit approaching=\(below.isApproachingLimit)"
        case .limitReached: state = "limitReached"
        @unknown default: state = "unknown(limitReached=\(usage.isLimitReached))"
        }
        print("[pcc-spike] quota \(label): \(state) reset=\(usage.resetDate.map { "\($0)" } ?? "nil")")
    }
}
#endif
