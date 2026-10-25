package com.benjaminissa.issareader.core

import java.io.File

/**
 * The one directory everything this app writes lives under.
 *
 * On iOS and macOS this is Application Support: the system never purges it, so
 * a book downloaded for a flight is still there when there is no network to
 * fetch it again. On Android the app hands over its own `Context.filesDir`,
 * which is the same promise: private to the app, and never reclaimed under
 * storage pressure. Each writer marks its own subtree as it needs.
 *
 * **Caches on tvOS**, because that is the platform's contract rather than a
 * preference: an Apple TV app may write only to Caches and tmp, and a
 * directory under Application Support fails with "You don't have permission to
 * save the file …" — exactly the error a reader saw when the first download on
 * a real Apple TV failed. The purgeable case exists here too, as the default:
 * until the app has said where its files go, the root is under the process's
 * temporary directory (on Android, the app's own cache), and a download, the
 * local catalogue or the log can vanish between launches. Every reader of
 * these files already copes with absence — a book is downloaded again, the
 * catalogue is rebuilt from the next fetch, a log starts over — so a forgotten
 * [configure] costs durability, never correctness.
 *
 * Nothing persists an absolute path under this root across launches: the store
 * is reopened by server key, a download resolves its destination when it
 * completes, fonts are re-registered from the directory at each launch. Moving
 * the root therefore needs no migration.
 */
object StorageRoot {
    private val defaultRoot = File(System.getProperty("java.io.tmpdir"), "issa-reader")

    @Volatile private var root: File = defaultRoot
    @Volatile private var cacheRoot: File = File(defaultRoot, "Caches")
    @Volatile private var purgeable: Boolean = true

    /**
     * Says where the app's files live: [root] for everything durable (on
     * Android `Context.filesDir`), [caches] for what the system may reclaim
     * (`Context.cacheDir`: the cover cache). Called once, before anything
     * writes; the app does it in `Application.onCreate`.
     */
    fun configure(root: File, caches: File, isPurgeable: Boolean = false) {
        this.root = root
        cacheRoot = caches
        purgeable = isPurgeable
    }

    /** The root itself. */
    val url: File get() = root

    /** Where the system may reclaim files: the cover cache lives here. */
    val caches: File get() = cacheRoot

    /**
     * `root/<name>/`. Does not create it; every caller creates what it needs
     * with intermediates, which also creates the root itself.
     */
    fun directory(name: String): File = File(root, name)

    /**
     * True where the system may reclaim this root. For documentation and
     * tests — no behaviour branches on it.
     */
    val isPurgeable: Boolean get() = purgeable
}
