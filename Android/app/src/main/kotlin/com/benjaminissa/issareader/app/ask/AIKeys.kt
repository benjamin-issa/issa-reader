package com.benjaminissa.issareader.app.ask

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.ask.AskAnswerer
import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.ProviderKind
import com.benjaminissa.issareader.ask.ProviderModel
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

/**
 * The reader's own AI keys: which providers they registered, with which model.
 *
 * Advanced and opt-in. Nothing here exists until a reader adds a key in
 * Settings › Advanced and agrees to the screen that says what will be sent,
 * and to whom. Until then the Ask sheet has no picker and nothing changes.
 *
 * - **The key is sealed on this phone only**: a file in `noBackupFilesDir`,
 *   encrypted with an Android Keystore key under its own alias. It is never
 *   in a backup or a device transfer, never in the preferences, never logged.
 * - **The registration — provider, model, when — is in the preferences**,
 *   which do travel in a backup. So a provider counts as registered only while
 *   its key reads back: a backup restored to another phone brings the
 *   registration and not the key, and that phone has no key.
 * - **Removed only by the reader**, or with the app. Signing out of the server
 *   does not touch it: the key is the reader's account with the provider, not
 *   with the server.
 *
 * Main-thread only, and observable through Compose snapshot state.
 */
class AIKeys(
    private val keyStore: TokenPersisting,
    private val defaults: KeyValueStore,
    private val now: () -> Long = System::currentTimeMillis,
) {
    /** One registered key: the provider, the model chosen for it, and when it was added. */
    data class Registration(val kind: ProviderKind, val model: ProviderModel, val added: Long)

    /** A registration as the preferences hold it: the provider by its name, as Swift's `Codable` writes it. */
    @Serializable
    private data class Stored(val kind: String, val model: ProviderModel, val added: Long)

    /** Registered providers whose key reads back, oldest first. */
    var registrations: List<Registration> by mutableStateOf(emptyList())
        private set

    /**
     * Every registration in the preferences, readable key or not. What is
     * saved: a key that would not read back this once is not a registration
     * to forget for good.
     */
    private var stored: List<Registration> = load()

    init {
        refresh()
    }

    /**
     * Reads again which keys read back. Called when Ask or Settings opens, so
     * a key unreadable at launch counts once it can be read.
     */
    fun refresh() {
        val readable = stored.filter { keyStore.read(it.kind.rawValue) != null }
        if (readable != registrations) registrations = readable
    }

    /** The providers a question can be sent to, in the order they were added. */
    val registered: List<ProviderKind> get() = registrations.map { it.kind }

    val hasAny: Boolean get() = registrations.isNotEmpty()

    fun registration(kind: ProviderKind): Registration? = registrations.firstOrNull { it.kind == kind }

    /** The key, read when a question is sent and at no other time. */
    fun key(kind: ProviderKind): String? {
        if (registration(kind) == null) return null
        return keyStore.read(kind.rawValue)
    }

    /**
     * Saves a key the reader has agreed to use, with the model they chose.
     * False when the key could not be stored, and nothing is registered then.
     */
    fun register(kind: ProviderKind, key: String, model: ProviderModel): Boolean {
        val trimmed = key.trim()
        if (trimmed.isEmpty() || !keyStore.write(trimmed, kind.rawValue)) {
            IssaLog.error("ask key could not be saved", mapOf("provider" to kind.rawValue))
            return false
        }
        val added = stored.firstOrNull { it.kind == kind }?.added ?: now()
        stored = (stored.filter { it.kind != kind } + Registration(kind, model, added)).sortedBy { it.added }
        save()
        refresh()
        IssaLog.info("ask key registered", mapOf("provider" to kind.rawValue, "model" to model.id))
        return true
    }

    /** Another model for a key already registered. */
    fun choose(model: ProviderModel, kind: ProviderKind) {
        if (stored.none { it.kind == kind }) return
        stored = stored.map { if (it.kind == kind) it.copy(model = model) else it }
        save()
        refresh()
        IssaLog.info("ask key model changed", mapOf("provider" to kind.rawValue, "model" to model.id))
    }

    /** Deletes the key and forgets the registration. */
    fun remove(kind: ProviderKind) {
        keyStore.delete(kind.rawValue)
        stored = stored.filter { it.kind != kind }
        save()
        refresh()
        IssaLog.info("ask key removed", mapOf("provider" to kind.rawValue))
    }

    private fun load(): List<Registration> {
        val text = defaults.getString(REGISTRATIONS_KEY) ?: return emptyList()
        val decoded = runCatching { IssaJson.decodeFromString(ListSerializer(Stored.serializer()), text) }.getOrNull()
            ?: return emptyList()
        return decoded.mapNotNull { entry ->
            ProviderKind.fromRawValue(entry.kind)?.let { Registration(it, entry.model, entry.added) }
        }.sortedBy { it.added }
    }

    private fun save() {
        val entries = stored.map { Stored(it.kind.rawValue, it.model, it.added) }
        defaults.putString(REGISTRATIONS_KEY, IssaJson.encodeToString(ListSerializer(Stored.serializer()), entries))
    }

    companion object {
        /** Where the registrations are kept: the backed-up preferences, never the keys. */
        const val REGISTRATIONS_KEY = "issa.ask.providerKeys"

        /** The Keystore alias the keys are sealed under, apart from the sign-in token's. */
        const val KEYSTORE_ALIAS = "issa.askkeys"

        /** The folder in `noBackupFilesDir` the sealed keys are written to. */
        const val DIRECTORY = "AskKeys"
    }
}

/**
 * A key store that holds nothing and keeps nothing: what a coordinator built
 * for a test gets unless the test hands it keys of its own.
 */
object NoKeys : TokenPersisting {
    override fun read(account: String): String? = null

    override fun write(token: String, account: String): Boolean = false

    override fun delete(account: String): Boolean = true
}

/**
 * Where a new question starts.
 *
 * As it always has, unless the reader has said otherwise: on the phone. A
 * registered provider when the reader made it the default — and on a phone
 * that can **never** run Gemini Nano, the first provider they added, because
 * there it is the only thing that can.
 *
 * A phone whose Gemini Nano is merely still downloading is not that phone.
 * Its reader's default stays where they left it: a question goes to a
 * provider only because they chose it, and the sheet says why the phone
 * cannot answer yet rather than quietly sending it elsewhere.
 */
object AskDefaults {
    /**
     * @param deviceSupported whether this phone can run Gemini Nano at all —
     *   ready, downloading, or not asked yet.
     */
    fun answerer(settings: PlaybackSettings, registered: List<ProviderKind>, deviceSupported: Boolean): AskAnswerer {
        val chosen = ProviderKind.fromRawValue(settings.askDefaultProvider)
        if (chosen != null && chosen in registered) return AskAnswerer.of(chosen)
        if (!deviceSupported) return registered.firstOrNull()?.let(AskAnswerer::of) ?: AskAnswerer.DEVICE
        return AskAnswerer.DEVICE
    }

    /**
     * Every place a question could go from here, in the order the picker lists
     * them. The phone is listed wherever it could ever answer, so a reader
     * whose Gemini Nano is downloading still sees it chosen.
     */
    fun choices(registered: List<ProviderKind>, deviceSupported: Boolean): List<AskAnswerer> =
        (if (deviceSupported) listOf(AskAnswerer.DEVICE) else emptyList()) + registered.map(AskAnswerer::of)

    /**
     * Whether ML Kit's answer is a phone that could answer at all. Not yet
     * asked counts as one: the switch is what asks.
     */
    fun supported(availability: AskAvailability?): Boolean = when (availability) {
        null, AskAvailability.AVAILABLE, AskAvailability.MODEL_DOWNLOADING, AskAvailability.MODEL_DOWNLOADABLE,
        AskAvailability.NEEDS_SYSTEM_UPDATE,
        -> true
        AskAvailability.UNSUPPORTED_DEVICE, AskAvailability.APPLE_INTELLIGENCE_OFF,
        AskAvailability.UNSUPPORTED_ON_THIS_PLATFORM,
        -> false
    }

    /** The picker's label for a place. */
    fun choiceTitle(answerer: AskAnswerer, model: String? = null, noun: String = AskDevice.noun): String = when (answerer) {
        AskAnswerer.DEVICE -> "This $noun · ${AskCopy.ASSISTANT}"
        AskAnswerer.ANTHROPIC, AskAnswerer.OPENAI -> model?.let { "${answerer.placeName} · $it" } ?: answerer.placeName
    }

    /** The sentence under the picker: what leaves the phone, and to whom. */
    fun caption(answerer: AskAnswerer, noun: String = AskDevice.noun): String = when (answerer) {
        AskAnswerer.DEVICE -> "Answered on this $noun. Nothing leaves it."
        AskAnswerer.ANTHROPIC, AskAnswerer.OPENAI ->
            "Sends your question and the book so far to ${answerer.placeName}, using your key."
    }
}
