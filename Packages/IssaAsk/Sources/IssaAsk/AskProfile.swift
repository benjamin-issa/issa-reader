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

    public init(
        name: String,
        instructions: String = AskPromptBuilder.instructions,
        usesSearchTool: Bool = AskEngine.usesSearchTool,
        excerptLimit: Int? = nil,
        recencyPassages: Int = AskRetriever.Limits.recencyPassages,
        passageCeiling: Int? = nil,
        responseTokens: Int = AskPromptBuilder.Budget.responseTokens,
        reasoning: AskGenerationOptions.Reasoning? = nil,
    ) {
        self.name = name
        self.instructions = instructions
        self.usesSearchTool = usesSearchTool
        self.excerptLimit = excerptLimit
        self.recencyPassages = recencyPassages
        self.passageCeiling = passageCeiling
        self.responseTokens = responseTokens
        self.reasoning = reasoning
    }

    /// 1.7.1's engine, unchanged.
    public static let shipped = AskProfile(name: "shipped")

    /// What the app asks the on-device model with.
    public static let device = AskProfile(name: "device")

    /// What the app asks Apple's servers with.
    public static let cloud = AskProfile(name: "cloud")

    /// The profile for a place.
    public static func `for`(_ answerer: AskAnswerer) -> AskProfile {
        switch answerer {
        case .device: device
        case .cloud: cloud
        }
    }
}
