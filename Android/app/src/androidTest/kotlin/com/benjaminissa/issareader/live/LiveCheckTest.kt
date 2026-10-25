package com.benjaminissa.issareader.live

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.SystemClock
import android.util.Base64
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.regex.Pattern

/**
 * The release rule's live checks, driven on a phone or emulator against a real
 * Storyteller rather than the layout sweep's fixture: the Android twin of
 * `Apps/IssaLiveUITests/Sources/LiveServerTests.swift`, check for check.
 *
 * Every other suite talks to a stub, a captured response or a fixture library,
 * and the iPhone's worst bugs got past all of them: the cover redirect that
 * signed readers out only happened on a real 3.x server, once covers began to
 * load. So this signs the real app into a real server, the way a reader would,
 * and looks at what it shows.
 *
 * It does nothing on its own. `scripts/android-live-check.sh` installs the app
 * afresh, puts the server's books where the checks need them, passes the lot
 * in as instrumentation arguments (base64, since adb hands the command line to
 * the device's shell), approves the pairing code this writes out, and checks
 * the server afterwards — which is where "reading a page saved a position" is
 * actually decided. Without a `server` argument every test here skips, so a
 * plain `connectedAndroidTest` stays offline.
 *
 * No hook in the app: it is launched by its own launcher intent and found
 * through what Swift's accessibility identifiers name, carried as Compose
 * test tags the app exposes as resource ids, and through its accessibility
 * labels and state descriptions — what TalkBack reads.
 */
@RunWith(AndroidJUnit4::class)
class LiveCheckTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device: UiDevice = UiDevice.getInstance(instrumentation)
    private val context: Context get() = instrumentation.targetContext
    private val arguments = InstrumentationRegistry.getArguments()

    /** One of the script's settings, decoded, or null when it passed none. */
    private fun setting(name: String): String? =
        arguments.getString(name)
            ?.let { String(Base64.decode(it, Base64.DEFAULT), Charsets.UTF_8) }
            ?.takeIf { it.isNotEmpty() }

    /**
     * Where the pairing code, screenshots and verdicts go: the app's own files,
     * which the script reads back through `run-as`. The test runs in the app's
     * process, so these are the app's to write.
     */
    private val out: File by lazy { File(context.filesDir, "live-check").apply { mkdirs() } }

    private var shots = 0
    private val failures = mutableListOf<String>()

    @Before
    fun setUp() {
        assumeTrue(
            "needs a live server: run scripts/android-live-check.sh, which passes the server",
            setting("server") != null,
        )
    }

    /**
     * One method, not one per check: each needs the one before it — no
     * library without a sign-in, no Settings row without a session — and
     * splitting would buy a pairing per check and an order nobody chose.
     */
    @Test
    fun theReleaseChecksAgainstALiveServer() {
        val server = setting("server")!!
        launch()

        val landed = signIn(server)
        record("signIn", landed, if (landed) signInMethod else "never reached the library")
        if (landed) {
            sessionSurvives()
            serverVersion()
            statusLabel()
            readAPage()
            if (setting("audio") == "1") readAlong()

            // Again at the end: a session that survived the covers can still be
            // lost to a reader's download or a position write.
            val end = signedIn()
            record("sessionAtEnd", end.first, end.second)
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    // region Checks

    /** How the run got in, for the summary. */
    private var signInMethod = "already signed in"

    /** Types the server, asks for a device code, and hands the code to the script. */
    private fun signIn(server: String): Boolean {
        val deadline = SystemClock.uptimeMillis() + 60_000
        while (SystemClock.uptimeMillis() < deadline && !exists("screen.signIn") && !isLanded()) sleep(1_000)
        if (isLanded()) return true
        if (!exists("screen.signIn")) return false

        val field = device.wait(Until.findObject(By.res("field.serverAddress")), 30_000) ?: return false
        // Set through accessibility rather than typed: no keyboard comes up to
        // cover the button below, and a field that remembered a server is
        // replaced rather than typed after.
        field.text = server
        capture("typed")
        val useCode = device.wait(Until.findObject(By.text("Use a device code")), 10_000) ?: return false
        useCode.click()

        // Four minutes: the script's approver drives a real browser through
        // Storyteller's sign-in and approval pages, and the app then polls at
        // the server's interval. The code is found by its spoken shape — one
        // character at a time, "B S 5 3 - Y L N P" — which nothing else has.
        val shape = Pattern.compile("^[A-Z0-9]( [A-Z0-9-]){6,}$")
        var written = false
        val pairing = SystemClock.uptimeMillis() + 240_000
        while (SystemClock.uptimeMillis() < pairing) {
            if (isLanded()) return true
            if (!written) {
                val spoken = node { it.contentDescription?.toString()?.let(shape::matcher)?.matches() == true }
                    ?.contentDescription?.toString()
                if (spoken != null) {
                    written = write(spoken.replace(" ", ""), "code.txt")
                    if (written) {
                        signInMethod = "paired with device code"
                        capture("code")
                    }
                }
            }
            sleep(1_000)
        }
        return false
    }

    /**
     * The session outlives the covers: they are what signed the iPhone's 1.2.0
     * out, since 3.x answers the cover route with a redirect. Thirty seconds
     * on the library with no sign-in screen is the check.
     */
    private fun sessionSurvives() {
        selectTab("Library")
        val books = device.wait(Until.findObject(By.res(Pattern.compile("^(cell\\.book\\.|rail\\.).*"))), 90_000)
        record("library", books != null, if (books != null) "the library shows its books" else "no rail or book cell appeared")
        sleep(30_000)
        capture("library")
        val survived = signedIn()
        record(
            "session",
            survived.first,
            if (survived.first) "still signed in 30 s after the covers" else "while covers loaded: ${survived.second}",
        )
    }

    /** Settings › Advanced shows the version the script expects. */
    private fun serverVersion() {
        selectTab("Settings")
        val list = device.wait(Until.findObject(By.res("screen.settings")), 20_000)
        if (list == null) {
            record("serverVersion", false, "Settings never appeared")
            return
        }
        val advanced = scrollTo(list) { device.findObject(By.text("Advanced")) }
        if (advanced == null) {
            record("serverVersion", false, "no Advanced row in Settings")
            return
        }
        advanced.click()
        sleep(1_000)
        scrollTo(list) { device.findObject(By.res("settings.serverVersion")) }
        capture("advanced")
        val row = node { it.viewIdResourceName == "settings.serverVersion" }
        if (row == null) {
            record("serverVersion", false, "no Server version row under Advanced")
            return
        }
        // The row's value is its state description, the version alone.
        val shown = row.stateDescription?.toString()
            ?: row.text?.toString()?.removePrefix("Server version, ")
            ?: ""
        val expected = setting("expectVersion")
        if (expected == null) {
            record("serverVersion", true, "shows \"$shown\" (nothing expected)")
        } else {
            record("serverVersion", shown == expected, "shows \"$shown\", expected \"$expected\"")
        }
    }

    /**
     * A book's status pill shows the server's label for its status. Reached
     * through a library search rather than a link: a link opens the reader,
     * and opening a book is exactly what could change its status.
     */
    private fun statusLabel() {
        val expected = setting("statusLabel")
        val title = setting("statusTitle")
        if (expected == null || title == null) {
            record("statusLabel", false, "not run: no status book given")
            return
        }
        selectTab("Library")
        val field = device.wait(Until.findObject(By.clazz("android.widget.EditText")), 20_000)
        if (field == null) {
            record("statusLabel", false, "no library search field")
            return
        }
        // The library searches as it is typed into, so setting the text is the search.
        field.text = title
        sleep(1_000)

        // By uuid where the script knows it: two editions can share a title.
        val tag = setting("statusBook")?.let { "cell.book.$it" }
        val cell = device.wait(
            Until.findObject(if (tag != null) By.res(tag) else By.res(Pattern.compile("^cell\\.book\\..*"))),
            20_000,
        )
        if (cell == null) {
            record("statusLabel", false, "\"$title\" is not in the library")
            return
        }
        cell.click()
        val labels = setOf("Change reading status", "Set reading status")
        val pill = waitForNode(20_000) { it.contentDescription?.toString() in labels }
        if (pill == null) {
            record("statusLabel", false, "no status pill on \"$title\"")
            return
        }
        capture("status")
        val shown = pill.stateDescription?.toString() ?: ""
        record("statusLabel", shown == expected, "\"$title\" shows \"$shown\", expected \"$expected\"")
        device.pressBack()
    }

    /**
     * Opens a book, turns three pages, and waits for the position to leave.
     * The turn is judged by the page itself: its label is the page's text and
     * its state "Page N of M in <chapter>", read before the taps and after.
     * Whether the position reached the server is the script's to check.
     */
    private fun readAPage() {
        val book = setting("readBook")
        if (book == null) {
            record("readerOpened", false, "not run: no book to read given")
            return
        }
        openReader(book, 120_000)?.let {
            record("readerOpened", false, "$book: $it")
            return
        }
        val before = pageReading()
        if (before == null) {
            capture("reader")
            record("readerOpened", false, "the reader opened $book but drew no page")
            return
        }
        capture("reader")
        repeat(3) {
            // The right edge turns forward; the middle would toggle the bars.
            tap(0.92, 0.5)
            sleep(1_500)
        }
        val after = pageReading()
        sleep(15_000)
        capture("reader-turned")
        if (after == null) {
            record("readerOpened", false, "the page went away while turning")
            return
        }
        val turned = after != before
        record(
            "readerOpened",
            turned,
            if (turned) "turned from \"${before.second}\" to \"${after.second}\"" else "three taps on the right edge left the page at \"${before.second}\"",
        )
        val closed = closeReader()
        record("readerClosed", closed == null, closed ?: "Back to the book closed the reader")
    }

    /**
     * Plays a read-along past the end of its first audio file. Only stopping
     * is judged here — a player looping at the file's end still shows Pause —
     * and whether it got past is the script's to decide from the position.
     */
    private fun readAlong() {
        val book = setting("readalongBook")
        if (book == null) {
            record("readAlong", false, "--audio given but no read-along book")
            return
        }
        openReader(book, 240_000)?.let {
            record("readAlong", false, "$book: $it")
            return
        }
        var play = device.findObject(By.desc("Play narration"))
        repeat(3) {
            if (play != null) return@repeat
            // The bars may be hidden; the middle of the page shows them.
            tap(0.5, 0.5)
            play = device.wait(Until.findObject(By.desc("Play narration")), 5_000)
        }
        val button = play
        if (button == null) {
            record("readAlong", false, "no Play narration button")
            return
        }
        button.click()
        if (device.wait(Until.findObject(By.desc("Pause narration")), 30_000) == null) {
            record("readAlong", false, "narration did not start")
            return
        }
        val seconds = setting("readalongSeconds")?.toLongOrNull() ?: 75
        sleep(seconds * 1_000)
        capture("readalong")
        val pause = device.findObject(By.desc("Pause narration"))
        record("readAlong", pause != null, if (pause != null) "still playing after $seconds s" else "stopped before $seconds s")
        pause?.click()
        // The pause is a position like any other, saved after the debounce,
        // and the script reads what it leaves.
        sleep(10_000)
    }

    // endregion

    // region Helpers

    private val packageName: String get() = context.packageName

    private fun launch() {
        val intent = context.packageManager.getLaunchIntentForPackage(packageName)!!
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        context.startActivity(intent)
        device.wait(Until.hasObject(By.pkg(packageName).depth(0)), 30_000)
    }

    private fun exists(tag: String): Boolean = device.hasObject(By.res(tag))

    /** Signed in, on either tab a session opens on. */
    private fun isLanded(): Boolean = exists("screen.reading") || exists("screen.library")

    private fun signedOut(): Boolean = exists("screen.signIn") || device.hasObject(By.text("Your session has ended."))

    /**
     * Signed in, on the evidence of something a signed-in app shows, not only
     * the absence of the sign-in screen: an app that has gone shows none either.
     */
    private fun signedIn(): Pair<Boolean, String> {
        if (device.currentPackageName != packageName) {
            return false to "the app is not in the foreground (${device.currentPackageName} is)"
        }
        if (signedOut()) return false to "signed out"
        val onATab = isLanded() || exists("screen.settings") || exists("screen.bookDetail")
        val inTheReader = device.hasObject(By.desc("Back to the book")) || pageNode() != null
        if (!onATab && !inTheReader) return false to "no signed-in screen and no reader on show"
        return true to "still signed in"
    }

    /** Opens a book by the link a widget uses, past the first-run guide. Null once it is up and clear. */
    private fun openReader(book: String, timeout: Long): String? {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse("issareader://book/$book"))
                .setPackage(packageName)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        val deadline = SystemClock.uptimeMillis() + timeout
        while (SystemClock.uptimeMillis() < deadline && pageNode() == null && guide() == null) sleep(1_000)
        if (pageNode() == null && guide() == null) {
            capture("reader-never-ready")
            return if (exists("screen.reader")) "the reader opened but drew no page within ${timeout / 1_000} s" else "the reader never opened"
        }
        dismissGuide(5_000)?.let { return it }
        if (waitForNode(10_000) { isPage(it) } == null) {
            capture("reader-no-page")
            return "the reading guide went, and no page was under it"
        }
        return null
    }

    /** The reader's first-run guide, by what it says. */
    private fun guide(): AccessibilityNodeInfo? = node {
        val label = it.contentDescription?.toString() ?: it.text?.toString() ?: return@node false
        label.startsWith("Reading gestures") || label.startsWith("This book is narrated")
    }

    /** Dismisses the guide with a tap on it, as a reader does. Null when none is left. */
    private fun dismissGuide(wait: Long): String? {
        val deadline = SystemClock.uptimeMillis() + wait
        while (guide() == null && SystemClock.uptimeMillis() < deadline) sleep(500)
        if (guide() == null) return null
        capture("guide")
        tap(0.5, 0.5)
        val gone = SystemClock.uptimeMillis() + 10_000
        while (guide() != null && SystemClock.uptimeMillis() < gone) sleep(500)
        if (guide() != null) {
            capture("guide-stuck")
            return "the reading guide did not go away when tapped"
        }
        return null
    }

    private fun isPage(node: AccessibilityNodeInfo): Boolean = node.stateDescription?.toString()?.startsWith("Page ") == true

    private fun pageNode(): AccessibilityNodeInfo? = node(::isPage)

    /** The page's text and its place, together: either changing is a turn. */
    private fun pageReading(): Pair<String, String>? =
        pageNode()?.let { (it.contentDescription?.toString() ?: "") to (it.stateDescription?.toString() ?: "") }

    /** The bars on screen, showing them with a tap in the middle if they have hidden. */
    private fun showBars(): UiObject2? {
        device.wait(Until.findObject(By.desc("Back to the book")), 5_000)?.let { return it }
        tap(0.5, 0.5)
        return device.wait(Until.findObject(By.desc("Back to the book")), 5_000)
    }

    /** Closes the reader with its Back button. Null once it has gone. */
    private fun closeReader(): String? {
        dismissGuide(0)?.let { return it }
        val back = showBars()
        if (back == null) {
            capture("close-no-bars")
            return "no Back to the book button to close the reader with"
        }
        back.click()
        if (!device.wait(Until.gone(By.res("screen.reader")), 15_000)) {
            capture("reader-not-closed")
            return if (guide() != null) "the reader did not close: the reading guide took the tap" else "the reader did not close: Back to the book left it on screen"
        }
        return null
    }

    /** A tab by its title, in the navigation bar. */
    private fun selectTab(title: String) {
        val tab = device.wait(Until.findObject(By.text(title).clickable(true)), 30_000)
            ?: device.wait(Until.findObject(By.text(title)), 5_000)
        if (tab == null) {
            record("tab", false, "no $title tab")
            return
        }
        tab.click()
        sleep(1_000)
    }

    /** Swipes [list] up until [find] answers, at most eight times. */
    private fun scrollTo(list: UiObject2, find: () -> UiObject2?): UiObject2? {
        repeat(8) {
            find()?.let { return it }
            list.scroll(Direction.DOWN, 0.6f)
            sleep(400)
        }
        return find()
    }

    private fun tap(x: Double, y: Double) {
        device.click((device.displayWidth * x).toInt(), (device.displayHeight * y).toInt())
    }

    /**
     * The first node in the active window that answers [predicate]: for what
     * UI Automator's selectors cannot name, a state description above all.
     */
    private fun node(predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val root = instrumentation.uiAutomation.rootInActiveWindow ?: return null
        val queue = ArrayDeque(listOf(root))
        while (queue.isNotEmpty()) {
            val next = queue.removeFirst()
            if (predicate(next)) return next
            for (i in 0 until next.childCount) next.getChild(i)?.let(queue::addLast)
        }
        return null
    }

    private fun waitForNode(timeout: Long, predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val deadline = SystemClock.uptimeMillis() + timeout
        while (true) {
            node(predicate)?.let { return it }
            if (SystemClock.uptimeMillis() > deadline) return null
            sleep(500)
        }
    }

    /** One verdict line for the script's summary, and a failure for the run's own result. */
    private fun record(check: String, passed: Boolean, detail: String) {
        File(out, "checks.txt").appendText("$check ${if (passed) "PASS" else "FAIL"} $detail\n")
        if (!passed) failures += "$check: $detail"
    }

    /** Atomic, because the script polls for the code and must never read half of one. */
    private fun write(text: String, name: String): Boolean = runCatching {
        val partial = File(out, "$name.part")
        partial.writeText(text)
        check(partial.renameTo(File(out, name)))
    }.isSuccess

    /** A numbered PNG, so the files sort in the order the run took them. */
    private fun capture(name: String) {
        shots += 1
        device.takeScreenshot(File(out, "%02d-%s.png".format(shots, name)))
    }

    private fun sleep(millis: Long) = SystemClock.sleep(millis)

    // endregion
}
