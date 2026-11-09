package com.benjaminissa.issareader.core.diagnostics

import com.benjaminissa.issareader.core.networking.StorytellerError
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.io.File
import java.time.Duration
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * The app's own log, kept so a beta tester can hand over what happened.
 *
 * The platform's log can only be read back for the running process, and the
 * reports worth having are about the launch *before* the one you are looking
 * at — so this writes its own file.
 *
 * Deliberately small: append a line, keep six hours, redact the secrets.
 * Everything else is the caller's job.
 *
 * Lives under [com.benjaminissa.issareader.core.StorageRoot], not in a cache:
 * a system empties caches under storage pressure, which is one of the
 * conditions a report would be about.
 *
 * Takes the place of `os.Logger` too: core has no Android types in it, so
 * this sink is the only one it writes to.
 */
object IssaLog {
    @Serializable
    enum class Level {
        @SerialName("debug") DEBUG,
        @SerialName("info") INFO,
        @SerialName("warning") WARNING,
        @SerialName("error") ERROR,
        ;

        /** Swift's raw value: `debug`, `info`, `warning`, `error`. */
        val rawValue: String get() = name.lowercase()
    }

    /** How far back an export reaches. */
    val window: Duration = Duration.ofHours(6)

    // Writing

    fun debug(message: String, fields: Map<String, String> = emptyMap()) = write(Level.DEBUG, message, fields)

    fun info(message: String, fields: Map<String, String> = emptyMap()) = write(Level.INFO, message, fields)

    fun warning(message: String, fields: Map<String, String> = emptyMap()) = write(Level.WARNING, message, fields)

    fun error(message: String, fields: Map<String, String> = emptyMap()) = write(Level.ERROR, message, fields)

    /**
     * Records a thrown error at a named site.
     *
     * The point of the whole exercise: thirteen `catch` blocks used to discard
     * the error entirely, and several of them are exactly what a beta report
     * would be about.
     */
    fun failure(site: String, error: Throwable, fields: Map<String, String> = emptyMap()) {
        val all = fields.toMutableMap()
        all["site"] = site
        all.putAll(describe(error))
        write(Level.ERROR, "$site failed", all)
    }

    /**
     * What is worth keeping about an error, beyond the sentence shown to the
     * reader — which is the part that is already known and the least useful.
     *
     * For anything that is not a [StorytellerError], the exception's class
     * stands where Swift records an `NSError`'s domain and code: it is what
     * identifies a JVM failure (`java.net.UnknownHostException`), and there is
     * no numeric code to go with it.
     */
    internal fun describe(error: Throwable): Map<String, String> {
        val fields = mutableMapOf("error" to error.toString())
        if (error is StorytellerError) {
            when (error) {
                is StorytellerError.Server -> {
                    fields["status"] = error.status.toString()
                    error.serverMessage?.let { fields["serverMessage"] = it }
                }
                is StorytellerError.Transport -> fields["transport"] = error.reason
                is StorytellerError.Download -> fields["download"] = error.reason
                is StorytellerError.Decoding -> fields["decoding"] = error.detail
                else -> Unit
            }
            fields["retryable"] = error.isRetryable.toString()
        } else {
            fields["domain"] = error.javaClass.name
        }
        return fields
    }

    internal fun write(level: Level, message: String, fields: Map<String, String>) {
        store.append(entry(level, message, fields))
    }

    /**
     * Builds the entry that would be written, redaction and all.
     *
     * Separate from [write] so a test can assert on what *would* reach the
     * file without writing one. A test that rebuilt this itself would pass
     * with the redaction removed, which is the one thing it exists to catch.
     */
    internal fun entry(
        level: Level,
        message: String,
        fields: Map<String, String>,
        at: Instant = Instant.now(),
    ): Entry = Entry(
        time = at,
        level = level,
        message = Redaction.scrub(message),
        // A field *named* as a secret loses its value outright; anything else
        // is scrubbed for secrets that turn up inside it.
        fields = fields.mapValues { (key, value) ->
            if (Redaction.isSecret(key)) "«redacted»" else Redaction.scrub(value)
        },
    )

    // Reading

    /** Everything from the last six hours, oldest first, as plain text. */
    fun export(): String = store.text(Instant.now().minus(window))

    /** Writes the export to a file for sharing, and returns it. */
    fun exportFile(): File? = store.exportFile(Instant.now().minus(window))

    /** Number of entries currently held, for the screen that offers the export. */
    fun count(): Int = store.count(Instant.now().minus(window))

    fun clear() = store.clear()

    /**
     * Writes everything buffered, now.
     *
     * `append` buffers and schedules a flush on a background thread, because a
     * page turn can log several times in a few milliseconds and opening the
     * file for each would put disk I/O on the main thread during the one
     * animation that must not stutter. Nothing called this, though — so the
     * entries immediately before a crash, a force-quit or a suspension that
     * the system then kills are exactly the ones that never reached the file,
     * and they are the entries this log exists to capture.
     *
     * Called from the app's own stop and terminate handlers — and `suspend`,
     * on the I/O dispatcher, so that it is not done *on* them: the first
     * version was synchronous, which put lock-held file I/O on the main thread
     * inside the window the system gives an app that is going away.
     */
    suspend fun flush() = withContext(Dispatchers.IO) { store.flush() }

    /**
     * Writes everything buffered *before this function returns*.
     *
     * The narrow case [flush] cannot serve: a line written immediately before
     * a call that may abort the process. Scheduling the write — even awaiting
     * it — loses the race, because an abort does not run pending work. Five
     * CarPlay crash reports came with a diagnostics export taken ninety
     * seconds later that contained not one line about CarPlay, because every
     * entry from that launch was still pending.
     *
     * The cost [flush]'s comment warns about is real and is accepted here:
     * this is lock-held file I/O on the caller's thread. Use it where a few
     * milliseconds are affordable and losing the line is not — which is
     * approximately nowhere except the moment before handing an argument to a
     * framework that validates it by throwing.
     */
    fun flushNow() = store.flush()

    /** Removes any diagnostics file written for sharing. */
    fun discardExports() = store.discardExports()

    /** Where the log is, so the diagnostics screen can say so. */
    val directory: File? get() = store.directory

    internal val store = LogStore()

    // An entry

    @Serializable
    data class Entry(
        @Serializable(with = StampSerializer::class) val time: Instant,
        val level: Level,
        val message: String,
        val fields: Map<String, String>,
    ) {
        /**
         * One line, readable by a person first and a parser second. A beta
         * report gets read by eye long before anything parses it.
         */
        val line: String
            get() {
                val stamp = STAMP.format(time)
                val extras = fields.entries
                    .sortedBy { it.key }
                    .joinToString(" ") { "${it.key}=${it.value}" }
                val level = level.rawValue.uppercase().padEnd(7, ' ')
                return if (extras.isEmpty()) "$stamp $level $message" else "$stamp $level $message  $extras"
            }

        companion object {
            /**
             * ISO 8601 with milliseconds, in UTC: `2026-08-30T03:51:47.123Z`.
             * The same stamp the Swift log writes.
             */
            internal val STAMP: DateTimeFormatter =
                DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)
        }
    }

    /**
     * Writes [Entry.time] with its milliseconds, and reads either form back.
     *
     * Not a stamp without fractions: a page turn logs several entries in a few
     * milliseconds — rounding them to the same whole second is exactly what
     * makes a report unable to say which happened first. Files written before
     * the fractional form existed carry whole seconds, and a format change
     * must not cost their lines, so both parse.
     */
    internal object StampSerializer : KSerializer<Instant> {
        override val descriptor: SerialDescriptor =
            PrimitiveSerialDescriptor("com.benjaminissa.issareader.core.diagnostics.Stamp", PrimitiveKind.STRING)

        override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(Entry.STAMP.format(value))

        override fun deserialize(decoder: Decoder): Instant = Instant.parse(decoder.decodeString())
    }

    // Redaction

    /**
     * Keeping secrets out of a file whose whole purpose is to be sent to
     * somebody else.
     *
     * Redaction happens on the way *in*, not on the way out: a file that has
     * held a token for six hours has already been backed up, indexed and
     * possibly synced, and scrubbing the export would be too late.
     */
    object Redaction {
        /** Field names whose value is never recorded, whatever it looks like. */
        internal val secretKeys: Set<String> = linkedSetOf(
            "authorization", "token", "access_token", "accesstoken",
            "refresh_token", "refreshtoken", "device_code", "devicecode",
            "user_code", "usercode", "password", "secret", "client_secret",
            // A username is a credential too, and the password form's wire
            // field is literally `usernameOrEmail`, so a future call site that
            // logged the form body would be scrubbed on both halves rather
            // than one.
            "username", "usernameoremail", "username_or_email",
        )

        private val bearer = Regex("(?i)bearer\\s+[A-Za-z0-9._~+/=-]+")
        private val userinfo = Regex("://[^/@\\s]+@")
        private val keyed: List<Pair<String, Regex>> = secretKeys.map { key ->
            key to Regex("(?i)\"?$key\"?\\s*[=:]\\s*\"?[A-Za-z0-9._~+/=-]+\"?")
        }
        private val userCode = Regex("(?<![A-Za-z0-9-])[A-Z0-9]{4}-[A-Z0-9]{4}(?![A-Za-z0-9-])")

        fun scrub(text: String): String {
            var result = text
            // `Bearer <token>` wherever it appears in prose.
            result = result.replace(bearer, "Bearer «redacted»")
            // Credentials typed into the address itself: `https://user:pw@host`.
            // The server address is logged everywhere a request can fail, and
            // it also rides inside transport error descriptions, so no
            // call-site rule could catch it. The whole userinfo goes — a
            // username is a credential too — and the host stays, or the log
            // cannot be matched against anything.
            result = result.replace(userinfo, "://«redacted»@")
            // `key=value` and `"key": "value"` for anything named as a secret.
            // The quote after the key is optional too: without it the JSON
            // shape — the one a logged body would take — never matched, as
            // `"token"` puts a quote between the key and its colon.
            for ((key, pattern) in keyed) {
                result = result.replace(pattern, "$key=«redacted»")
            }
            // A user code as the app shows it: four, a dash, four — and
            // nothing adjacent. Without the guards this also matches the middle
            // of a UUID, and redacting the task identifiers out of a network
            // error leaves a log that cannot be correlated with anything.
            result = result.replace(userCode, "«code»")
            return result
        }

        /** Whether a field name means "do not record the value". */
        fun isSecret(key: String): Boolean = key.lowercase().replace("-", "_") in secretKeys
    }
}
