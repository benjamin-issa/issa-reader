package com.benjaminissa.issareader.core

import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import java.util.UUID

/**
 * What Swift's `JSONSerialization.data(withJSONObject:)` does for a test:
 * maps, lists, strings, numbers, booleans and `null` (Swift's `NSNull()`) as
 * JSON.
 */
fun jsonOf(value: Any?): JsonElement = when (value) {
    null -> JsonNull
    is JsonElement -> value
    is String -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Map<*, *> -> JsonObject(value.entries.associate { (key, item) -> key as String to jsonOf(item) })
    is List<*> -> JsonArray(value.map { jsonOf(it) })
    else -> error("not JSON: $value")
}

/** A book decoded from [json], as every Swift suite builds one: the model is otherwise only ever decoded. */
fun decodeBook(json: Map<String, Any?>): Book = IssaJson.decodeFromJsonElement(Book.serializer(), jsonOf(json))

/** The bare minimum a book's JSON carries: every required array, empty. */
fun bookJson(uuid: String, title: String): MutableMap<String, Any?> = mutableMapOf(
    "uuid" to uuid, "title" to title,
    "authors" to emptyList<Any>(), "narrators" to emptyList<Any>(), "creators" to emptyList<Any>(),
    "series" to emptyList<Any>(), "collections" to emptyList<Any>(), "identifiers" to emptyList<Any>(),
    "tags" to emptyList<Any>(),
)

/** A captured response, by its name under IssaCore's `Tests/Fixtures`, without `.json`: Swift's `BookDecodingTests.fixture`. */
fun fixture(name: String): String = Fixtures.core("$name.json").readText()

fun fixtureBooks(name: String): List<Book> = IssaJson.decodeFromString(ListSerializer(Book.serializer()), fixture(name))

fun fixtureStatuses(name: String): List<Status> = IssaJson.decodeFromString(ListSerializer(Status.serializer()), fixture(name))

/** A fresh directory under the temporary directory, not yet created. */
fun temporaryDirectory(prefix: String): File = File(System.getProperty("java.io.tmpdir"), "$prefix-${UUID.randomUUID()}")

/**
 * Asserts that [block] throws a [T], and returns it: Swift's `#expect(throws:)`,
 * for code that suspends. Inline, so [block] may call suspend functions.
 */
inline fun <reified T : Throwable> assertThrowing(message: String = "", block: () -> Unit): T {
    try {
        block()
    } catch (e: Throwable) {
        if (e is T) return e
        throw AssertionError("expected ${T::class.java.simpleName}, got $e. $message", e)
    }
    throw AssertionError("expected ${T::class.java.simpleName}, nothing was thrown. $message")
}

/** Runs [block] with a fresh temporary directory, and removes it afterwards. */
inline fun <T> withTemporaryDirectory(prefix: String, block: (File) -> T): T {
    val directory = temporaryDirectory(prefix)
    try {
        return block(directory)
    } finally {
        directory.deleteRecursively()
    }
}
