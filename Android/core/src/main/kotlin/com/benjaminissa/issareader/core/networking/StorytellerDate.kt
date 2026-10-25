package com.benjaminissa.issareader.core.networking

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.time.format.ResolverStyle
import java.util.Locale

/**
 * Storyteller emits three different date formats, sometimes in one object.
 *
 * All three verified against a live `web-v2.14.21` server:
 * - Row timestamps (`createdAt`, `updatedAt`) come straight out of SQLite as
 *   `"2026-08-30 03:51:47"` — space-separated, no timezone, implicitly UTC.
 * - Metadata dates (`publicationDate`) are ISO 8601 with milliseconds and a
 *   `Z` suffix: `"1998-06-01T00:00:00.000Z"`.
 * - `alignedAt` is a raw JavaScript `Date.toString()`:
 *   `"Sun Aug 30 2026 05:01:37 GMT+0000 (Coordinated Universal Time)"`.
 *
 * The third only appears once a book has been aligned, which is why it can lie
 * dormant until the first readaloud shows up and then fail the whole library
 * decode at once.
 *
 * A single date strategy cannot cover these, so this type wraps the parsing
 * and models declare [FlexibleDate] properties.
 */
object StorytellerDate {
    /** UTC, a fixed locale, the ISO calendar — never the device's calendar or locale. */
    private val sqlite: DateTimeFormatter = DateTimeFormatter.ofPattern("uuuu-MM-dd HH:mm:ss", Locale.ROOT)
        .withResolverStyle(ResolverStyle.STRICT)
        .withZone(ZoneOffset.UTC)

    /**
     * JavaScript's `Date.toString()`, e.g.
     * "Sun Aug 30 2026 05:01:37 GMT+0000 (Coordinated Universal Time)".
     * The trailing parenthetical timezone name is stripped before parsing,
     * because its wording is locale- and platform-dependent.
     */
    private val javascript: DateTimeFormatter =
        DateTimeFormatter.ofPattern("EEE MMM dd uuuu HH:mm:ss 'GMT'Z", Locale.US)
            .withResolverStyle(ResolverStyle.STRICT)

    /** Parses any of the three shapes, or returns `null` for anything else. */
    fun parse(string: String): Instant? {
        try {
            return LocalDateTime.parse(string, sqlite).toInstant(ZoneOffset.UTC)
        } catch (_: DateTimeParseException) {
        }
        // ISO 8601, with and without fractional seconds.
        try {
            return OffsetDateTime.parse(string, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
        } catch (_: DateTimeParseException) {
        }

        // Strip the human-readable timezone name JavaScript appends.
        val withoutZoneName = if ('(' in string) string.substringBefore('(').trim() else string
        try {
            return OffsetDateTime.parse(withoutZoneName, javascript).toInstant()
        } catch (_: DateTimeParseException) {
        }
        return null
    }

    /** Renders in the SQLite shape the server uses for row timestamps. */
    fun sqliteString(from: Instant): String = sqlite.format(from)
}

/**
 * A date that decodes from any Storyteller date format.
 *
 * A malformed value throws rather than silently yielding a wrong instant — a
 * book that sorts to 1970 is much harder to notice than a decode error.
 *
 * Encoded in the SQLite shape, as Swift's `FlexibleDate` encodes itself: the
 * local store keeps a re-encoding of each `Book`, and the two clients write
 * it the same way.
 */
@Serializable(with = FlexibleDate.Serializer::class)
data class FlexibleDate(val value: Instant) : Comparable<FlexibleDate> {
    override fun compareTo(other: FlexibleDate): Int = value.compareTo(other.value)

    internal object Serializer : KSerializer<FlexibleDate> {
        override val descriptor: SerialDescriptor =
            PrimitiveSerialDescriptor("com.benjaminissa.issareader.core.networking.FlexibleDate", PrimitiveKind.STRING)

        override fun serialize(encoder: Encoder, value: FlexibleDate) {
            encoder.encodeString(StorytellerDate.sqliteString(value.value))
        }

        override fun deserialize(decoder: Decoder): FlexibleDate {
            val raw = decoder.decodeString()
            val parsed = StorytellerDate.parse(raw)
                ?: throw SerializationException("Unrecognised Storyteller date format: $raw")
            return FlexibleDate(parsed)
        }
    }
}
