package com.benjaminissa.issareader.ask

import kotlinx.serialization.Serializable
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl

/**
 * An AI provider a reader can register their own key for, in Settings ›
 * Advanced.
 *
 * Never a default and never the mainstream path: a reader who adds a key has
 * chosen to send their questions, and the passages of the book needed to
 * answer them, to that company under their own account. Everything the app
 * says about it — the consent screen, the caption under the Ask field, the
 * origin pill — names the company, because that is who receives the text.
 */
enum class ProviderKind(val rawValue: String) {
    ANTHROPIC("anthropic"),
    OPENAI("openai"),
    ;

    /** The company, as a reader knows it. */
    val displayName: String
        get() = when (this) {
            ANTHROPIC -> "Anthropic"
            OPENAI -> "OpenAI"
        }

    /**
     * Where the key is made, in words rather than a link: a key needs credit
     * bought from the provider, and the app does not point at a purchase.
     */
    val keyInstructions: String
        get() = when (this) {
            ANTHROPIC -> "Create a key in the Anthropic Console, under API keys. Questions you ask are billed to that account."
            OPENAI -> "Create a key on the OpenAI platform, under API keys. Questions you ask are billed to that account."
        }

    /**
     * What the provider says it does with what it is sent, for the consent
     * screen. Worded from each provider's own published policy (checked 20 Nov
     * 2026) — and kept to what the policy commits to, not what the app hopes.
     */
    val retentionSentence: String
        get() = when (this) {
            ANTHROPIC ->
                "Anthropic says it doesn't train its models on what's sent with an API key, and deletes it within 30 days " +
                    "unless it's needed to enforce its usage policy or the law."
            OPENAI ->
                "OpenAI says it doesn't train its models on what's sent with an API key. It keeps it for up to 30 days " +
                    "to check for abuse; the app asks it to store nothing else."
        }

    /** The provider's privacy policy, linked from the consent screen. */
    val privacyPolicyUrl: String
        get() = when (this) {
            ANTHROPIC -> "https://www.anthropic.com/legal/privacy"
            OPENAI -> "https://openai.com/policies/privacy-policy/"
        }

    /** The API's root. */
    val baseUrl: HttpUrl
        get() = when (this) {
            ANTHROPIC -> "https://api.anthropic.com/v1/".toHttpUrl()
            OPENAI -> "https://api.openai.com/v1/".toHttpUrl()
        }

    /**
     * The model preselected when a key is registered, if the key can use it:
     * each provider's best in the 1.8.0 study (Claude Opus 5.5 94%, GPT-6.2 Sol
     * 97%, on 144 questions from the reader's library).
     */
    val preferredModelId: String
        get() = when (this) {
            ANTHROPIC -> "claude-opus-5-5"
            OPENAI -> "gpt-6.2-sol"
        }

    /**
     * Models the provider study measured with the app's prompts, marked
     * "Tested with Issa Reader" in the list a reader chooses from.
     */
    val testedModelIds: Set<String>
        get() = when (this) {
            ANTHROPIC -> setOf("claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5")
            OPENAI -> setOf("gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-terra", "gpt-6-luna")
        }

    companion object {
        /** The provider a stored name stands for, or null for one this build does not know. */
        fun fromRawValue(raw: String?): ProviderKind? = entries.firstOrNull { it.rawValue == raw }
    }
}

/**
 * One model a reader's key can use, as the provider listed it.
 *
 * Stored with the key's registration (not the key itself — that is in the
 * Keystore-sealed file), so the app can say which model answered without
 * asking the provider again.
 */
@Serializable
data class ProviderModel(
    val id: String,
    /** What the provider calls it, or a readable form of the id. */
    val displayName: String,
    /** The whole window, as the provider reported it or as the app knows it. */
    val contextSize: Int,
    /** When the provider released it, in seconds since 1970, for newest-first ordering. */
    val created: Long? = null,
    /**
     * Whether the model takes an effort (Anthropic) or reasoning effort
     * (OpenAI) setting. Sending one to a model that does not is a 400.
     */
    val supportsEffort: Boolean = false,
)
