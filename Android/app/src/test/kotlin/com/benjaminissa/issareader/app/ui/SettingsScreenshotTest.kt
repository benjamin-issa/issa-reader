package com.benjaminissa.issareader.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import com.benjaminissa.issareader.app.ui.local.LocalBookInfoContent
import com.benjaminissa.issareader.app.ui.local.LocalBooksContent
import com.benjaminissa.issareader.app.ui.local.LocalSettingsContent
import com.benjaminissa.issareader.app.ui.player.NowPlayingSheetContent
import com.benjaminissa.issareader.app.ui.settings.ControlsSettingsScreen
import com.benjaminissa.issareader.app.ui.settings.DiagnosticsScreen
import com.benjaminissa.issareader.app.ui.settings.DownloadsScreen
import com.benjaminissa.issareader.app.ui.settings.FontLicencesScreen
import com.benjaminissa.issareader.app.ui.settings.LicenceTextScreen
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.app.ui.settings.ReadingSettingsScreen
import com.benjaminissa.issareader.app.ui.settings.SettingsRootList
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.download.DownloadsInventory
import com.benjaminissa.issareader.playback.ControlSurface
import com.benjaminissa.issareader.render.HighlighterChoice
import com.benjaminissa.issareader.render.HighlighterPreset
import com.benjaminissa.issareader.render.ReaderTheme
import com.benjaminissa.issareader.ui.IssaTheme
import com.benjaminissa.issareader.ui.Palette
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The Settings tree, the player and "On this phone", drawn from a small fixed
 * state, for comparing by eye with the iPhone's (`docs/screenshots`). The
 * pictures land in `app/build/settings-shots/` when the suite runs with
 * `-Proborazzi.test.record=true`.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class SettingsScreenshotTest {
    private val fixture = SettingsFixture()

    @After
    fun tearDown() = fixture.close()

    private fun shot(name: String, dark: Boolean = false, content: @Composable () -> Unit) {
        fixture.withLibrary().withLocalBooks()
        captureRoboImage("build/settings-shots/$name.png") {
            IssaTheme(darkTheme = dark) {
                CompositionLocalProvider(LocalAppEnvironment provides fixture.environment) {
                    Box(Modifier.fillMaxSize().background(Palette.paper)) { content() }
                }
            }
        }
    }

    @Composable
    private fun Root(advanced: Boolean = false) {
        SettingsRootList(
            app = fixture.app,
            settings = fixture.settings,
            nowPlaying = fixture.nowPlaying,
            local = fixture.local,
            account = SettingsFixture.account,
            onNavigate = {},
            onOpenLocalBooks = {},
            initiallyAdvanced = advanced,
        )
    }

    // Settings

    @Test
    fun settingsRoot() = shot("settings-402") { Root() }

    @Test
    @Config(qualifiers = "w375dp-h667dp-xxhdpi")
    fun settingsRootSmall() = shot("settings-375") { Root() }

    @Test
    @Config(qualifiers = "w440dp-h956dp-xxhdpi")
    fun settingsRootLarge() = shot("settings-440") { Root() }

    @Test
    fun settingsRootAdvanced() = shot("settings-advanced-402") { Root(advanced = true) }

    @Test
    @Config(qualifiers = "w402dp-h1640dp-xxhdpi")
    fun settingsRootAdvancedWhole() = shot("settings-advanced-whole-402") { Root(advanced = true) }

    @Test
    fun settingsRootDark() = shot("settings-402-dark", dark = true) { Root() }

    @Test
    fun controls() = shot("controls-402") { ControlsSettingsScreen(fixture.settings, onBack = {}) }

    @Test
    fun controlsCar() = shot("controls-car-402") { ControlsSettingsScreen(fixture.settings, onBack = {}, initialSurface = ControlSurface.CAR) }

    @Test
    @Config(qualifiers = "w402dp-h1960dp-xxhdpi")
    fun reading() {
        fixture.settings.readerStyle = fixture.settings.readerStyle.copy(
            highlighters = mapOf(ReaderTheme.PAPER to HighlighterChoice.Preset(HighlighterPreset.MOSS)),
        )
        readingWhole()
    }

    private fun readingWhole() = shot("reading-whole-402") {
        ReadingSettingsScreen(fixture.settings, onBack = {}, onOpenLicences = {}, reduceMotion = false)
    }

    @Test
    fun readingTop() = shot("reading-402") { ReadingSettingsScreen(fixture.settings, onBack = {}, onOpenLicences = {}, reduceMotion = false) }

    @Test
    fun downloads() = shot("downloads-402") {
        DownloadsScreen(fixture.app, onBack = {}, scanned = downloadsInventory())
    }

    @Test
    fun diagnostics() = shot("diagnostics-402") {
        DiagnosticsScreen(onBack = {}, preview = DIAGNOSTICS_TAIL to 214)
    }

    @Test
    fun fontsAndLicences() = shot("fonts-licences-402") { FontLicencesScreen(onBack = {}, onOpen = {}) }

    @Test
    fun licenceText() = shot("licence-literata-402") { LicenceTextScreen("font-literata", onBack = {}) }

    // On this phone

    @Test
    fun localEmpty() {
        captureRoboImage("build/settings-shots/local-empty-402.png") {
            IssaTheme(darkTheme = false) {
                CompositionLocalProvider(LocalAppEnvironment provides fixture.environment) {
                    Box(Modifier.fillMaxSize().background(Palette.paper)) { localEmptyContent() }
                }
            }
        }
    }

    @Composable
    private fun localEmptyContent() {
        LocalBooksContent(fixture.environment, fixture.local, standalone = false, onConnectServer = {}, onBack = {}, sizes = emptyMap(), freeSpace = 23_400_000_000)
    }

    @Test
    fun localTwoBooks() = shot("local-books-402") {
        LocalBooksContent(fixture.environment, fixture.local, standalone = false, onConnectServer = {}, onBack = {}, sizes = SettingsFixture.localSizes, freeSpace = 23_400_000_000)
    }

    @Test
    fun localStandalone() = shot("local-standalone-402") {
        LocalBooksContent(fixture.environment, fixture.local, standalone = true, onConnectServer = {}, onBack = null, sizes = SettingsFixture.localSizes, freeSpace = 23_400_000_000)
    }

    @Test
    fun localInfo() = shot("local-info-402") {
        LocalBookInfoContent(
            book = SettingsFixture.localBooks[0],
            isMissing = false,
            coverCache = fixture.coverCache,
            onDone = {}, onOpen = {}, onAddAgain = {}, onRemove = {},
            modifier = Modifier.fillMaxSize(),
        )
    }

    @Test
    fun localSettings() = shot("local-settings-402") {
        LocalSettingsContent(fixture.environment, fixture.local, onDone = {}, onConnectServer = {}, spaceUsed = 152_610_000)
    }

    // The player

    @Composable
    private fun Player(playing: Boolean) {
        NowPlayingSheetContent(
            book = SettingsFixture.peterAndWendy,
            session = null,
            coordinator = FixturePlayback(playing),
            chapterTitle = null,
            environment = fixture.environment,
            onDone = {},
            onReadAlong = {},
            modifier = Modifier.fillMaxSize(),
        )
    }

    @Test
    fun playerPlaying() = shot("player-playing-402") { Player(playing = true) }

    @Test
    fun playerPaused() = shot("player-paused-402") { Player(playing = false) }

    @Test
    fun playerDark() = shot("player-playing-402-dark", dark = true) { Player(playing = true) }

    private fun downloadsInventory(): DownloadsInventory {
        val books = SettingsFixture.serverBooks
        val key = { index: Int, format: BookContentService.Format -> DownloadsInventory.FileKey(books[index].uuid, format) }
        val files = mapOf(
            key(0, BookContentService.Format.READALOUD) to 412_000_000L,
            key(1, BookContentService.Format.READALOUD) to 655_300_000L,
            key(2, BookContentService.Format.EBOOK) to 1_800_000L,
            key(3, BookContentService.Format.EBOOK) to 900_000L,
            DownloadsInventory.FileKey("0b7d0c4e-0000-4000-8000-00000000dead", BookContentService.Format.EBOOK) to 2_400_000L,
        )
        return DownloadsInventory(
            books = books,
            downloaded = books.take(4).map { it.uuid }.toSet(),
            sizes = DownloadsInventory.Sizes(
                files = files,
                booksDirectoryBytes = files.values.sum(),
                extractedAudioBytes = 96_000_000,
                coverBytes = 6_300_000,
                askIndexBytes = 14_200_000,
                freeBytes = 41_700_000_000,
            ),
        )
    }

    private companion object {
        val DIAGNOSTICS_TAIL = """
            2026-10-25 09:41:02.118 INFO    app launched version=1.5.1 os=Android 16
            2026-10-25 09:41:02.405 INFO    local library loaded books=2 missing=0
            2026-10-25 09:41:03.012 INFO    server detected generation=v3 version=3.0.0-beta.49
            2026-10-25 09:41:03.377 INFO    library refreshed books=6
            2026-10-25 09:42:15.640 INFO    reader opened book=Peter and Wendy
            2026-10-25 09:42:16.002 INFO    narration started chapter=7
        """.trimIndent()
    }
}
