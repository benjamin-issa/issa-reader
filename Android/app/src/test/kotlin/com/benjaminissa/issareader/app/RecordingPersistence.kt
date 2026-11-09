package com.benjaminissa.issareader.app

import com.benjaminissa.issareader.app.reader.ReaderPersistence
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.LocalBookFiles
import com.benjaminissa.issareader.core.model.LocalBookMetadata
import com.benjaminissa.issareader.core.model.LocalCopy
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.StoredPosition
import com.benjaminissa.issareader.core.model.local
import com.benjaminissa.issareader.core.sync.PositionOrigin
import java.io.File
import java.time.Instant
import java.util.UUID

/**
 * A [ReaderPersistence] that keeps nothing and counts everything, over a copy
 * of the read-along fixture in a folder of its own.
 */
class RecordingPersistence(val accepts: Boolean) : ReaderPersistence {
    val root: File = temporaryDirectory("issa-recording")
    val book: Book

    @Volatile var positions = 0
        private set

    @Volatile var anchors = 0
        private set

    init {
        val uuid = UUID.randomUUID().toString().lowercase()
        val files = LocalBookFiles(uuid, root)
        files.folder.mkdirs()
        files.epub.writeBytes(ReaderOpening.readalongFixture())
        book = Book.local(
            uuid = uuid,
            metadata = LocalBookMetadata(title = "The Patient Record of the Days"),
            narrationDuration = 32.75,
            copy = LocalCopy(fileName = "readalong.epub", fingerprint = "x", byteCount = 1, importedAt = Instant.now()),
        )
    }

    fun tearDown() {
        root.deleteRecursively()
    }

    override fun files(bookUuid: String): LocalBookFiles = LocalBookFiles(bookUuid, root)
    override suspend fun storedPosition(bookUuid: String): StoredPosition? = null

    override suspend fun writePosition(locator: ReadiumLocator, timestamp: Double, origin: PositionOrigin, bookUuid: String): Boolean {
        positions += 1
        return accepts
    }

    override suspend fun recordAudioAnchor(anchor: AudioAnchor, bookUuid: String) {
        anchors += 1
    }

    override suspend fun audioAnchor(bookUuid: String): AudioAnchor? = null
    override suspend fun annotations(bookUuid: String): List<Annotation> = emptyList()
    override fun save(annotation: Annotation) = Unit
    override fun delete(annotation: Annotation) = Unit
    override fun didOpen(bookUuid: String) = Unit
}
