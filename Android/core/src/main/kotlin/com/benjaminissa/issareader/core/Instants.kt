package com.benjaminissa.issareader.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.time.Instant
import java.time.temporal.ChronoUnit

/**
 * This instant as seconds since 1970, the way Swift's
 * `Date.timeIntervalSince1970` states it: one `Double`, fractions included.
 */
fun Instant.toEpochSecondsDouble(): Double = epochSecond + nano / 1_000_000_000.0

/**
 * The instant [seconds] after 1970, the inverse of [toEpochSecondsDouble]:
 * Swift's `Date(timeIntervalSince1970:)`.
 *
 * Rounded to the microsecond. A `Double` of this decade's epoch seconds
 * resolves about a quarter of a microsecond, so a value that went out as a
 * number — to JSON, to a database column — comes back a few hundred
 * nanoseconds off, and an `Instant` that differs in its nanoseconds is a
 * different `Instant`. Rounding here makes every microsecond-precise instant
 * (see [swiftNow]) survive the round trip exactly, as a Swift `Date`, which
 * *is* a `Double`, always does.
 */
fun instantOfEpochSeconds(seconds: Double): Instant {
    if (!seconds.isFinite()) return Instant.EPOCH
    val micros = Math.round(seconds * 1_000_000.0)
    return Instant.ofEpochSecond(Math.floorDiv(micros, 1_000_000L), Math.floorMod(micros, 1_000_000L) * 1_000L)
}

/**
 * Now, at the precision a Swift `Date` round-trips through a number: see
 * [instantOfEpochSeconds]. For defaults that stand in for Swift's `Date()`.
 */
fun swiftNow(): Instant = Instant.now().truncatedTo(ChronoUnit.MICROS)

/** Swift's reference date, 2001-01-01T00:00:00Z, in epoch seconds. */
internal const val SWIFT_REFERENCE_DATE_EPOCH_SECONDS = 978_307_200.0

/**
 * A `Date` as Swift's `JSONEncoder` writes one by default: a bare number, the
 * seconds since 2001-01-01 (`timeIntervalSinceReferenceDate`).
 *
 * Used for the records whose JSON shape the Swift client also writes —
 * annotations, a local book's copy, the widget's snapshot — so a record
 * written by one client has the shape the other writes.
 */
object SwiftDateSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("com.benjaminissa.issareader.core.SwiftDate", PrimitiveKind.DOUBLE)

    override fun serialize(encoder: Encoder, value: Instant) {
        encoder.encodeDouble(value.toEpochSecondsDouble() - SWIFT_REFERENCE_DATE_EPOCH_SECONDS)
    }

    override fun deserialize(decoder: Decoder): Instant =
        instantOfEpochSeconds(decoder.decodeDouble() + SWIFT_REFERENCE_DATE_EPOCH_SECONDS)
}
