package com.benjaminissa.issareader.core

import kotlinx.serialization.json.Json

/**
 * The one JSON configuration the client reads and writes the server's shapes
 * with.
 *
 * - Unknown keys are ignored: every newer server adds fields, and a client
 *   that refuses them stops working on the next upgrade (CLAUDE.md: every
 *   newly decoded field is optional).
 * - Absent values are omitted, not written as `null`, which is what Swift's
 *   `Codable` does. Storyteller stores a position's locator verbatim and
 *   compares stored and incoming locators by deep equality, so both clients
 *   have to write the same shape.
 * - A `null` for a non-nullable field with a default takes the default.
 */
val IssaJson: Json = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
    coerceInputValues = true
    isLenient = false
}
