package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.SwiftDateSerializer
import com.benjaminissa.issareader.core.swiftNow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

/**
 * A bookmark or a highlight the reader made.
 *
 * Storyteller stores positions and nothing else — no annotations endpoint
 * exists in 2.x or 3.x — so these live on the device. They are written with a
 * locator rather than a page number so they survive a font change, and with
 * the quoted text so they survive the publisher revising the chapter.
 *
 * Dates are written as Swift's `JSONEncoder` writes them (seconds since 2001),
 * so the record has the same shape on both clients.
 */
@Serializable
data class Annotation(
    val id: String = UUID.randomUUID().toString().uppercase(),
    @SerialName("bookUUID") val bookUuid: String,
    val kind: Kind,
    val tint: Tint = Tint.TANGERINE,
    /** Where it is, in the same terms as a saved reading position. */
    val locator: ReadiumLocator,
    /** The text that was marked, for the list and for re-anchoring. */
    val excerpt: String,
    /** The reader's own words, for a note. */
    val note: String? = null,
    val chapterTitle: String? = null,
    @Serializable(with = SwiftDateSerializer::class) val createdAt: Instant = swiftNow(),
    @Serializable(with = SwiftDateSerializer::class) val updatedAt: Instant = swiftNow(),
) {
    @Serializable
    enum class Kind {
        @SerialName("bookmark") BOOKMARK,
        @SerialName("highlight") HIGHLIGHT,
        @SerialName("note") NOTE,
        ;

        /** Swift's raw value: `bookmark`, `highlight`, `note`. */
        val rawValue: String get() = name.lowercase()
    }

    /**
     * The highlight colours the reader can pick from, named rather than stored
     * as hex so a future theme can restate them without migrating data.
     */
    @Serializable
    enum class Tint(val title: String) {
        @SerialName("tangerine") TANGERINE("Tangerine"),
        @SerialName("moss") MOSS("Moss"),
        @SerialName("slate") SLATE("Slate"),
        @SerialName("rose") ROSE("Rose"),
        @SerialName("plum") PLUM("Plum"),
    }

    companion object {
        /**
         * Sorts a book's annotations into reading order rather than the order
         * they happened to be made in, which is what a contents-style list
         * needs.
         */
        val readingOrder: Comparator<Annotation> = Comparator { a, b ->
            val left = a.locator.locations?.totalProgression ?: a.locator.locations?.progression ?: 0.0
            val right = b.locator.locations?.totalProgression ?: b.locator.locations?.progression ?: 0.0
            if (left != right) {
                left.compareTo(right)
            } else {
                (a.locator.locations?.charOffset ?: 0).compareTo(b.locator.locations?.charOffset ?: 0)
            }
        }
    }
}
