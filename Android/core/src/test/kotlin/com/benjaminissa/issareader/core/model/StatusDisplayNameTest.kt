package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.jsonOf
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * What a status is called on screen and to a screen reader. Ported from
 * `StatusDisplayNameTests.swift`.
 *
 * 3.x puts an admin's wording in `label` and nothing stops it being blank:
 * the admin dialog accepts a label of spaces, and the API accepts `""`.
 */
class StatusDisplayNameTest {
    /** Decoded, as the server sends it: the label is whatever the admin typed. */
    private fun status(label: String?): Status {
        val json = mutableMapOf<String, Any?>("uuid" to "s-read", "name" to Status.readName)
        if (label != null) json["label"] = label
        return IssaJson.decodeFromJsonElement(Status.serializer(), jsonOf(json))
    }

    /** An empty label falls back to the name. */
    @Test
    fun emptyLabel() {
        assertEquals(Status.readName, status(label = "").displayName)
    }

    /** A label of nothing but whitespace falls back to the name. */
    @Test
    fun whitespaceLabel() {
        assertEquals(Status.readName, status(label = " ").displayName)
        assertEquals(Status.readName, status(label = " \n\t ").displayName)
    }

    /**
     * A label with words in it is kept as sent. Only a label with nothing to
     * read is replaced; tidying one with words is the admin's call.
     */
    @Test
    fun paddedLabelIsKept() {
        assertEquals(" Finished ", status(label = " Finished ").displayName)
        assertEquals("Finished", status(label = "Finished").displayName)
    }

    /** No label at all is the name, as on 2.x. */
    @Test
    fun noLabel() {
        assertEquals(Status.readName, status(label = null).displayName)
    }
}
