package com.benjaminissa.issareader.testing

import java.io.File

/**
 * The Swift packages' fixtures, read in place.
 *
 * Captured server responses for every Storyteller generation the client
 * supports live in `Packages/IssaCore/Tests/Fixtures` (2.14.21 at the top
 * level, 2.14.23 in `v2-14-23/`, beta.40 in `v3/`, beta.46 in `v3/beta46/`,
 * beta.49 in `v3/beta49/`, beta.56 in `v3/beta56/`), and the books in each package's own
 * `Tests/Fixtures`. The Android suites read the same files, so a capture added
 * for one client is checked by both. Paths are repository-relative because the
 * same file name (`alice.epub`) exists in more than one package.
 */
object Fixtures {
    /** The repository root, set by the Gradle build as `issa.repoRoot`. */
    val repoRoot: File by lazy {
        System.getProperty("issa.repoRoot")?.let(::File)
            ?: generateSequence(File("").absoluteFile) { it.parentFile }
                .firstOrNull { File(it, "Packages/IssaCore/Tests/Fixtures").isDirectory }
            ?: error("issa.repoRoot is not set and no Packages/ directory is above ${File("").absolutePath}")
    }

    fun file(path: String): File {
        val file = File(repoRoot, path)
        check(file.exists()) { "Fixture $path is missing (looked in ${file.absolutePath})" }
        return file
    }

    fun bytes(path: String): ByteArray = file(path).readBytes()

    fun text(path: String): String = file(path).readText()

    /** A file in IssaCore's captured responses, e.g. `core("v3/beta49/books.json")`. */
    fun core(path: String): File = file("Packages/IssaCore/Tests/Fixtures/$path")
    fun epub(path: String): File = file("Packages/IssaEPUB/Tests/Fixtures/$path")
    fun render(path: String): File = file("Packages/IssaRender/Tests/Fixtures/$path")
    fun playback(path: String): File = file("Packages/IssaPlayback/Tests/Fixtures/$path")
    fun ask(path: String): File = file("Packages/IssaAsk/Tests/Fixtures/$path")
}
