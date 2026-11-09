package com.benjaminissa.issareader.core.diagnostics

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.StorageRoot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Where the log actually lives.
 *
 * A file rather than memory, because the report is usually about the launch
 * before the one you are looking at. Two files rather than one, because
 * trimming a single growing file means rewriting it on every append: the
 * current file is written until it passes `rotateAfter`, at which point it
 * becomes the previous one and a fresh file starts. Reading concatenates them
 * and drops anything outside the window.
 *
 * Locked rather than confined to a coroutine so that `IssaLog.error(…)` can
 * be called from anywhere — including a `catch` in a plain function, which is
 * most of them.
 *
 * @param root where to write, when it should not be the app's own log
 *   directory. Tests pass a temporary directory; nothing else does.
 */
class LogStore(private val root: File? = null) {
    private val lock = Any()

    /**
     * Held across a whole flush, and across a read, so that a reader cannot
     * observe the file after a background flush has claimed the buffer but
     * before it has written it — which loses entries silently, and did.
     * Reentrant because a read flushes first.
     */
    private val io = ReentrantLock()
    private val pending = mutableListOf<IssaLog.Entry>()
    private var flushing = false

    /**
     * Roughly a few thousand lines. Small enough to rewrite cheaply, large
     * enough that six hours of ordinary use rarely needs the previous file.
     */
    private val rotateAfter = 512 * 1024

    // Location

    /**
     * `Logs` under [StorageRoot], created on first use.
     *
     * Not a cache directory: a system empties those under storage pressure,
     * and "the device was low on space" is a thing a report needs to still be
     * able to say. Where the root is itself purgeable (see [StorageRoot]), a
     * purge costs the log — the platform's price, and better than no log file
     * at all. Keeping it out of a cloud backup is the app's backup rules' job
     * on Android; it is worthless off this device.
     */
    val directory: File?
        get() {
            if (root != null) {
                root.mkdirs()
                return root
            }
            val logs = StorageRoot.directory("Logs")
            if (!logs.exists()) logs.mkdirs()
            return logs
        }

    private val currentFile: File? get() = directory?.let { File(it, "current.log") }
    private val previousFile: File? get() = directory?.let { File(it, "previous.log") }

    // Writing

    /**
     * Buffers the entry and schedules a flush.
     *
     * Buffered because a page turn can log several times in a few
     * milliseconds, and opening the file for each would put disk I/O on the
     * main thread during the one animation that must not stutter.
     */
    fun append(entry: IssaLog.Entry) {
        val shouldSchedule: Boolean
        synchronized(lock) {
            pending.add(entry)
            shouldSchedule = !flushing
            flushing = true
        }
        if (!shouldSchedule) return
        flusher.launch { flush() }
    }

    /** Writes everything buffered. Safe to call from anywhere. */
    fun flush() {
        io.withLock {
            val batch: List<IssaLog.Entry>
            synchronized(lock) {
                batch = pending.toList()
                pending.clear()
                flushing = false
            }
            val current = currentFile
            if (batch.isEmpty() || current == null) return

            val data = buildString {
                for (entry in batch) {
                    val encoded = runCatching { IssaJson.encodeToString(IssaLog.Entry.serializer(), entry) }
                        .getOrNull() ?: continue
                    append(encoded)
                    append('\n')
                }
            }
            if (data.isEmpty()) return

            runCatching { FileOutputStream(current, true).use { it.write(data.encodeToByteArray()) } }
            rotateIfNeeded()
        }
    }

    private fun rotateIfNeeded() {
        val current = currentFile ?: return
        val previous = previousFile ?: return
        if (!current.exists() || current.length() <= rotateAfter) return
        previous.delete()
        current.renameTo(previous)
    }

    // Reading

    /** Every entry at or after [since], oldest first. */
    fun entries(since: Instant): List<IssaLog.Entry> = io.withLock {
        flush()
        val all = mutableListOf<IssaLog.Entry>()
        for (file in listOfNotNull(previousFile, currentFile)) {
            val text = runCatching { file.readText() }.getOrNull() ?: continue
            for (line in text.split('\n')) {
                if (line.isEmpty()) continue
                val entry = runCatching { IssaJson.decodeFromString(IssaLog.Entry.serializer(), line) }
                    .getOrNull() ?: continue
                if (!entry.time.isBefore(since)) all.add(entry)
            }
        }
        all.sortedBy { it.time }
    }

    fun count(since: Instant): Int = entries(since).size

    fun text(since: Instant): String {
        val lines = entries(since).map { it.line }
        if (lines.isEmpty()) return "No activity recorded in the last six hours."
        return lines.joinToString("\n")
    }

    /**
     * The export, as a file with a name worth receiving in a message.
     *
     * Written into a directory of its own with a random name. It used to land
     * on a date-stamped path directly in the temporary directory — guessable,
     * and never deleted. The diagnostics screen materialises it when it
     * appears, so merely opening that screen wrote six hours of hostnames and
     * book titles to disk whether or not the reader shared anything, including
     * straight after they tapped "Clear log". [discardExports] removes them.
     * (Swift also marks the file `completeFileProtection`; an Android app's
     * private storage has no per-file equivalent to ask for.)
     */
    fun exportFile(since: Instant): File? {
        val stamp = FILENAME_STAMP.format(Instant.now())
        val directory = exportDirectory
        directory.mkdirs()
        val file = File(directory, "IssaReader-$stamp-${UUID.randomUUID().toString().uppercase().take(8)}.log")
        val header = "Issa Reader diagnostics\n" +
            "Written ${IssaLog.Entry.STAMP.format(Instant.now())}\n" +
            "Covering the last six hours.\n\n"
        // Previous exports go first: one file per visit to the screen would
        // otherwise accumulate for the life of the install.
        discardExports()
        directory.mkdirs()
        val data = (header + text(since) + "\n").encodeToByteArray()
        return runCatching {
            val partial = File(directory, file.name + ".partial")
            partial.writeBytes(data)
            if (!partial.renameTo(file)) error("could not move the export into place")
            file
        }.getOrNull()
    }

    /** Removes every export written so far. */
    fun discardExports() {
        exportDirectory.deleteRecursively()
    }

    fun clear() {
        // Exports too. "Clear log" that leaves a full copy of the log in the
        // temporary directory is not what the button says it is.
        discardExports()
        io.withLock {
            synchronized(lock) { pending.clear() }
            for (file in listOfNotNull(previousFile, currentFile)) file.delete()
        }
    }

    companion object {
        /** `2026-08-30`, which sorts and survives every filesystem. */
        private val FILENAME_STAMP: DateTimeFormatter =
            DateTimeFormatter.ofPattern("yyyy-MM-dd").withZone(ZoneOffset.UTC)

        /** Where exports live, and the fact that they are ours to delete. */
        val exportDirectory: File get() = File(System.getProperty("java.io.tmpdir"), "issa-log-exports")

        /** Flushes run here, off the caller's thread, one at a time per store. */
        private val flusher = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }
}
