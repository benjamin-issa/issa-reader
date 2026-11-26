import Foundation

/// How the engine asks one model: what it is told, how much of the book it is
/// shown, whether it may search, and how hard it should think.
///
/// One value per place a question can be answered (`AskAnswerer`), because the
/// two models are not alike. The on-device model has a 4K window on most
/// phones and no reasoning; Apple's server model has 32K and can reason. A
/// profile is also the unit the accuracy study compares, so production and
/// measurement build their engines the same way, from the same values.
///
/// Every field defaults to what shipped in 1.7.1, so a profile that changes
/// nothing is the shipped engine exactly.
public struct AskProfile: Sendable, Hashable, Codable {
    /// For the log and the study's results — never shown to a reader.
    public var name: String
    /// The model's instructions. The question never goes here (it is the
    /// prompt's), so a reader cannot rewrite the rules by asking.
    public var instructions: String
    /// Whether the model may call `searchBook`.
    public var usesSearchTool: Bool
    /// How many excerpts retrieval may hand the builder. Nil scales with the
    /// model's window (`AskRetriever.Limits.excerpts(for:)`).
    public var excerptLimit: Int?
    /// How many of the passages just read are added behind what the search
    /// found.
    public var recencyPassages: Int
    /// The most tokens of excerpts a prompt may carry. Nil grows with the
    /// window from the 4K tuning (`AskPromptBuilder.Budget.passageCeiling`).
    public var passageCeiling: Int?
    /// The answer's own budget.
    public var responseTokens: Int
    /// How hard a model that can reason should think. Ignored by a model that
    /// cannot.
    public var reasoning: AskGenerationOptions.Reasoning?
    /// What of the book the model is shown.
    public var shape: ContextShape
    /// Whether the excerpts are scrubbed of the book's title, its authors and
    /// its chapter headings before they are sent (`BookIdentityScrubber`).
    ///
    /// On for a reader's own provider. Apple's models were measured without
    /// it, and their prompts are unchanged.
    public var scrubsBookIdentity: Bool

    /// What of the book goes with a question.
    public enum ContextShape: String, Sendable, Hashable, Codable {
        /// The passages retrieval found for the question, and the last few
        /// read — what every answerer was asked with until 1.8.0.
        case passages
        /// Everything before the reader's place, oldest dropped first if it
        /// does not fit `ceiling` tokens. Only a provider's window holds it.
        case everythingRead
    }

    /// The most tokens of book `everythingRead` may send.
    public var everythingReadCeiling: Int
    /// How the prompt is laid out (`AskPromptBuilder.PromptStyle`).
    public var promptStyle: AskPromptBuilder.PromptStyle
    /// Optional on-device semantic-span retrieval layered onto this profile.
    ///
    /// Keeping semantic retrieval as an optional overlay on top of the upstream
    /// profile (rather than a replacement profile) guarantees two invariants:
    /// 1. Previously serialised `AskProfile` JSON decodes cleanly (`nil`).
    /// 2. Whenever a book's embeddings are still catching up (`> 16` read spans
    ///    remaining) or the embedder fails, `AskEngine` falls straight back to
    ///    this profile's exact upstream behaviour (`everythingRead`, `searchBook`
    ///    tool, `60/40` cloud limits, or `15/12` device limits) with zero
    ///    degradation.
    public struct SemanticOptions: Sendable, Hashable, Codable {
        public var excerptLimit: Int?
        public var passageCeiling: Int?
        public var recencySpans: Int
        public var neighbourRadius: Int

        public init(
            excerptLimit: Int? = nil,
            passageCeiling: Int? = nil,
            recencySpans: Int = 3,
            neighbourRadius: Int = 1,
        ) {
            self.excerptLimit = excerptLimit
            self.passageCeiling = passageCeiling
            self.recencySpans = recencySpans
            self.neighbourRadius = neighbourRadius
        }

        /// Compact on-device semantic preset for 4K-window devices (iOS 26):
        /// keeps up to 10 distinct scenes with no ±1 neighbour expansion so
        /// tight context budgets preserve scene diversity.
        public static let deviceCompact = SemanticOptions(
            excerptLimit: 10,
            passageCeiling: nil,
            recencySpans: 2,
            neighbourRadius: 0,
        )

        /// Validated on-device semantic preset for 8K+ windows (up to 20 scenes
        /// with ±1 neighbouring context spans and 2 immediate recency spans,
        /// capped at 5,800 tokens). Upstream's exact instructions and tool
        /// configuration stay untouched.
        public static let device = SemanticOptions(
            excerptLimit: 20,
            passageCeiling: 5_800,
            recencySpans: 2,
            neighbourRadius: 1,
        )

        /// Selects the on-device semantic preset matching the model's context
        /// window (`<= 4_096` stays compact for scene diversity; larger windows
        /// use the 8K preset with ±1 neighbours).
        public static func device(forContextSize contextSize: Int) -> SemanticOptions {
            contextSize <= AskPromptBuilder.Budget.tunedContextSize ? .deviceCompact : .device
        }

        /// Semantic retrieval for Apple's 32K Private Cloud Compute window;
        /// upstream's exact instructions and `searchBook` tool stay untouched.
        public static let cloud = SemanticOptions(
            excerptLimit: 40,
            passageCeiling: 20_000,
            recencySpans: 6,
            neighbourRadius: 1,
        )

        /// Semantic retrieval for reader-owned providers (OpenAI / Anthropic):
        /// sends up to 45 semantic scenes + 8 recent spans (~15–20K tokens)
        /// when the book's read spans are embedded, while keeping upstream's
        /// exact provider instructions, prompt style, reminder, and `searchBook`
        /// tool untouched — and falling back to upstream's whole-book
        /// `everythingRead` whenever embeddings are not installed or catching up.
        public static let provider = SemanticOptions(
            excerptLimit: 45,
            passageCeiling: 20_000,
            recencySpans: 8,
            neighbourRadius: 1,
        )
    }

    /// For `.sandwich`: the rules, said again after the question.
    public var reminder: String?
    /// Optional semantic-span retrieval overlay (nil = upstream retrieval only).
    public var semantic: SemanticOptions?

    public init(
        name: String,
        instructions: String = AskPromptBuilder.instructions,
        usesSearchTool: Bool = AskEngine.usesSearchTool,
        excerptLimit: Int? = nil,
        recencyPassages: Int = AskRetriever.Limits.recencyPassages,
        passageCeiling: Int? = nil,
        responseTokens: Int = AskPromptBuilder.Budget.responseTokens,
        reasoning: AskGenerationOptions.Reasoning? = nil,
        shape: ContextShape = .passages,
        scrubsBookIdentity: Bool = false,
        everythingReadCeiling: Int = 0,
        promptStyle: AskPromptBuilder.PromptStyle = .plain,
        reminder: String? = nil,
        semantic: SemanticOptions? = nil,
    ) {
        self.promptStyle = promptStyle
        self.reminder = reminder
        self.semantic = semantic
        self.name = name
        self.instructions = instructions
        self.usesSearchTool = usesSearchTool
        self.excerptLimit = excerptLimit
        self.recencyPassages = recencyPassages
        self.passageCeiling = passageCeiling
        self.responseTokens = responseTokens
        self.reasoning = reasoning
        self.shape = shape
        self.scrubsBookIdentity = scrubsBookIdentity
        self.everythingReadCeiling = everythingReadCeiling
    }

    /// Returns a copy of this upstream profile with on-device semantic retrieval
    /// layered on top; every upstream field stays intact for mid-book fallback.
    public func withSemantic(_ options: SemanticOptions) -> AskProfile {
        var copy = self
        copy.semantic = options
        return copy
    }

    /// 1.7.1's engine, unchanged.
    public static let shipped = AskProfile(name: "shipped")

    /// What the app asks the on-device model with: the rules without the
    /// worked example, and no search tool. "D1" in the 1.8.0 accuracy study —
    /// about five points more accurate than 1.7.1's prompt on books no model
    /// can have memorised, and half the time to the first word.
    public static let device = AskProfile(
        name: "device",
        instructions: AskPromptBuilder.instructionsWithoutExample,
        usesSearchTool: false,
    )

    /// What the app asks Apple's servers with: the shipped rules, with room
    /// for the server model's 32K window — up to 60 excerpts, the last 40
    /// passages read, and a 20K-token ceiling for them — and the search tool.
    /// "C1" in the 1.8.0 study (right three times in four when it answered,
    /// and never wrong on those questions), with the tool kept at the reader's
    /// decision although the server model did not call it in the study either.
    public static let cloud = AskProfile(
        name: "cloud",
        usesSearchTool: true,
        excerptLimit: 60,
        recencyPassages: 40,
        passageCeiling: 20_000,
        responseTokens: 400,
    )

    /// What the app asks a reader's own provider with.
    ///
    /// Until the 1.8.0 provider study reports, the shipped rules with the
    /// worked example (a frontier model does not copy "Tobias" the way the
    /// 3B model did), the search tool, Apple's-servers-sized passages, and a
    /// light effort. The study decides the shape, the tool and the effort.
    ///
    /// - Parameter shape: what of the book is sent.
    /// - Parameter ceiling: the most tokens of book `everythingRead` sends —
    ///   below 100K on a model whose price rises past it.
    ///
    /// - Parameter kind: whose guidance the prompt follows — Claude's tagged
    ///   documents or GPT's XML with the rules repeated at the end. Nil is the
    ///   shipped prompt, unchanged, for the study to compare against.
    public static func provider(
        kind: ProviderKind? = nil,
        shape: ContextShape = .passages, ceiling: Int = 150_000,
        usesSearchTool: Bool = true, reasoning: AskGenerationOptions.Reasoning = .light,
    ) -> AskProfile {
        let instructions: String
        let style: AskPromptBuilder.PromptStyle
        let reminder: String?
        switch kind {
        case .anthropic:
            (instructions, style, reminder) = (AskPromptBuilder.anthropicInstructions, .tagged, nil)
        case .openAI:
            (instructions, style, reminder) = (
                AskPromptBuilder.openAIInstructions, .sandwich, AskPromptBuilder.openAIReminder,
            )
        case nil:
            (instructions, style, reminder) = (AskPromptBuilder.instructions, .plain, nil)
        }
        return AskProfile(
            name: "provider-\(kind?.rawValue ?? "shipped")-\(shape.rawValue)",
            instructions: instructions,
            usesSearchTool: usesSearchTool,
            excerptLimit: 60,
            recencyPassages: 40,
            passageCeiling: 20_000,
            responseTokens: 8_000,
            reasoning: reasoning,
            shape: shape,
            scrubsBookIdentity: true,
            everythingReadCeiling: ceiling,
            promptStyle: style,
            reminder: reminder,
        )
    }

    /// The provider profile for one model.
    ///
    /// Everything read so far, with the provider's own prompt: the 1.8.0
    /// provider study's choice. On two of the reader's library books it
    /// scored 94% (Claude Sonnet 5.5) and 96% (GPT-6.2 Sol) against 60% and
    /// 71% with passages, held every not-yet trap, and gave no spoiler, no
    /// wrong answer and no outside knowledge in 256 graded answers.
    ///
    /// Medium effort: on the same 32 questions it answered all but one
    /// answerable question across both models, against 94% and 96% on low,
    /// for about half a second more and much the same cost.
    ///
    /// The whole window: everything read so far is sent, up to the model's
    /// limit, and nothing is cut below it. The search is offered too, and when
    /// the book did not fit the prompt says its beginning was left out and to
    /// search it (`AskEngine.generateEverythingRead`): a reader halfway through
    /// a long book asked how something at its start came about, and the model,
    /// shown only its later part, could only say the story hadn't revealed it.
    public static func provider(for model: ProviderModel, kind: ProviderKind? = nil) -> AskProfile {
        provider(
            kind: kind, shape: .everythingRead, ceiling: model.contextSize, usesSearchTool: true,
            reasoning: .moderate,
        )
    }

    /// The profile for a place.
    public static func `for`(_ answerer: AskAnswerer) -> AskProfile {
        switch answerer {
        case .device: device
        case .cloud: cloud
        case .anthropic, .openAI: provider()
        }
    }
}
