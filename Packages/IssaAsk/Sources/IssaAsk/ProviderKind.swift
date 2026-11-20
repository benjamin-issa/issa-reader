import Foundation

/// An AI provider a reader can register their own key for, in Settings ›
/// Advanced.
///
/// Never a default and never the mainstream path: a reader who adds a key has
/// chosen to send their questions, and the passages of the book needed to
/// answer them, to that company under their own account. Everything the app
/// says about it — the consent screen, the caption under the Ask field, the
/// origin pill — names the company, because that is who receives the text.
public enum ProviderKind: String, Sendable, Hashable, Codable, CaseIterable {
    case anthropic
    case openAI = "openai"

    /// The company, as a reader knows it.
    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        }
    }

    /// Where the key is made, in words rather than a link: a key needs credit
    /// bought from the provider, and the app does not point at a purchase.
    public var keyInstructions: String {
        switch self {
        case .anthropic:
            "Create a key in the Anthropic Console, under API keys. Questions you ask are billed to that account."
        case .openAI:
            "Create a key on the OpenAI platform, under API keys. Questions you ask are billed to that account."
        }
    }

    /// What the provider says it does with what it is sent, for the consent
    /// screen. Worded from each provider's own published policy (checked 20 Nov
    /// 2026) — and kept to what the policy commits to, not what the app hopes.
    public var retentionSentence: String {
        switch self {
        case .anthropic:
            "Anthropic says it doesn't train its models on what's sent with an API key, and deletes it within 30 days unless it's needed to enforce its usage policy or the law."
        case .openAI:
            "OpenAI says it doesn't train its models on what's sent with an API key. It keeps it for up to 30 days to check for abuse; the app asks it to store nothing else."
        }
    }

    /// The provider's privacy policy, linked from the consent screen.
    public var privacyPolicyURL: URL {
        switch self {
        case .anthropic: URL(string: "https://www.anthropic.com/legal/privacy")!
        case .openAI: URL(string: "https://openai.com/policies/privacy-policy/")!
        }
    }

    /// The API's root.
    var baseURL: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com/v1/")!
        case .openAI: URL(string: "https://api.openai.com/v1/")!
        }
    }

    /// The model preselected when a key is registered, if the key can use it.
    ///
    /// The 1.8.0 provider study sets these; until it reports, each provider's
    /// own recommended starting point stands.
    public var preferredModelID: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openAI: "gpt-6.2-sol"
        }
    }

    /// Models the provider study measured with the app's prompts, marked
    /// "Tested" in the list a reader chooses from.
    public var testedModelIDs: Set<String> {
        switch self {
        case .anthropic: []
        case .openAI: []
        }
    }
}

/// One model a reader's key can use, as the provider listed it.
///
/// Stored with the key's registration (not the key itself — that is in the
/// Keychain), so the app can say which model answered without asking the
/// provider again.
public struct ProviderModel: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    /// What the provider calls it, or a readable form of the id.
    public var displayName: String
    /// The whole window, as the provider reported it or as the app knows it.
    public var contextSize: Int
    /// When the provider released it, for newest-first ordering.
    public var created: Date?
    /// Whether the model takes an effort (Anthropic) or reasoning effort
    /// (OpenAI) setting. Sending one to a model that does not is a 400.
    public var supportsEffort: Bool

    public init(
        id: String, displayName: String, contextSize: Int, created: Date? = nil,
        supportsEffort: Bool = false,
    ) {
        self.id = id
        self.displayName = displayName
        self.contextSize = contextSize
        self.created = created
        self.supportsEffort = supportsEffort
    }
}
