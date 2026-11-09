package com.benjaminissa.issareader.app

import android.net.Uri
import com.benjaminissa.issareader.app.local.LocalImport
import com.benjaminissa.issareader.app.local.LocalLibrary
import com.benjaminissa.issareader.core.model.LocalBookFiles
import com.benjaminissa.issareader.playback.MediaSupport
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.coroutines.CoroutineScope
import java.io.File

/**
 * A local library of a test's own: its `Local/` folder, its device store and
 * the folder its "picked" files come from, all under one temporary directory
 * that [tearDown] removes. Nothing here touches the app's real `Local/` or
 * `Store/`.
 *
 * Picked files are handed over as `file:` Uris, which the importer reads as
 * it reads a provider's `content:` ones, minus the provider.
 */
class LocalFixtures(
    val scope: CoroutineScope,
    val media: MediaSupport = TestMedia,
) {
    val base: File = temporaryDirectory("issa-local")
    val root: File get() = File(base, "Local")
    val storeDirectory: File get() = File(base, "Store")

    /** Where the reader's "Files" are: the picker hands over Uris in here. */
    val picked: File get() = File(base, "Picked")

    val library: LocalLibrary

    init {
        picked.mkdirs()
        library = make()
    }

    private fun make(): LocalLibrary = LocalLibrary(
        root = root,
        storeDirectory = storeDirectory,
        scope = scope,
        mediaSupport = media,
        contentResolver = null,
    ).also {
        // Short, so the tests that wait for them are not slow.
        it.addedHoldMillis = 10
    }

    /** A library over the same folders, as a relaunch would build it. */
    fun relaunched(): LocalLibrary = make()

    fun tearDown() {
        library.cancelAllImports()
        base.deleteRecursively()
    }

    /** One of the fixture books, copied into "Files" under [name]. */
    fun pick(resource: String, name: String? = null): Uri =
        pick(Fixtures.epub("$resource.epub").readBytes(), name ?: "$resource.epub")

    /** Bytes put in "Files" under [name]. */
    fun pick(data: ByteArray, name: String): Uri {
        val file = File(picked, name)
        file.writeBytes(data)
        return Uri.fromFile(file)
    }

    /** Imports and waits for the queue to finish, then returns the row. */
    suspend fun importAndWait(uri: Uri, reattaching: String? = null): LocalImport? {
        library.importBooks(listOf(uri), reattaching)
        library.importsSettled()
        return library.imports.lastOrNull { it.source == uri }
    }

    /** The `.incoming/` folder's contents: crash leftovers and copies in flight. */
    fun incoming(): List<String> = LocalBookFiles.incoming(root).list()?.toList() ?: emptyList()
}

/**
 * A device's decoders, as the suites need them: PCM, MP3 and AAC play, and
 * Opus does not.
 *
 * The Swift suites asked AVFoundation, which plays no Opus, and used an Opus
 * file as "narration in a format this device can't play". Android plays Opus,
 * so the same book would add as narrated on every emulator; this stands in for
 * a device without that decoder, which is what those tests are about. What the
 * real device decodes is `AndroidMediaSupport`'s, tested in `:playback-android`.
 */
object TestMedia : MediaSupport {
    private val playable = setOf("audio/wav", "audio/x-wav", "audio/wave", "audio/mpeg", "audio/mp4", "audio/aac", "audio/x-m4a")

    override fun isPlayable(mimeType: String): Boolean = mimeType.substringBefore(';').trim().lowercase() in playable

    override fun mimeType(extension: String): String? = when (extension.lowercase()) {
        "wav" -> "audio/wav"
        "mp3" -> "audio/mpeg"
        "m4a", "m4b", "mp4" -> "audio/mp4"
        "aac" -> "audio/aac"
        "opus" -> "audio/opus"
        else -> null
    }
}
