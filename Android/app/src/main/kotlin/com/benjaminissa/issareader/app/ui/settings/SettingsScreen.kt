package com.benjaminissa.issareader.app.ui.settings

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.benjaminissa.issareader.app.ask.AskCoordinator
import com.benjaminissa.issareader.app.local.LocalBooksCopy
import com.benjaminissa.issareader.app.local.LocalDevice
import com.benjaminissa.issareader.app.local.LocalLibrary
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.ui.ask.askSettingsSection
import com.benjaminissa.issareader.app.ui.shell.AppEnvironment
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.model.ServerCapabilities
import com.benjaminissa.issareader.playback.ProgressScope
import com.benjaminissa.issareader.ui.ButtonRow
import com.benjaminissa.issareader.ui.LabeledRow
import com.benjaminissa.issareader.ui.NavigationRow
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperRowFrame
import com.benjaminissa.issareader.ui.PaperSectionScope
import com.benjaminissa.issareader.ui.PickerRow
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.TitleAndValue
import com.benjaminissa.issareader.ui.paperSection
import kotlinx.coroutines.launch

/*
 * Settings, as the iPhone's Settings tab: `SettingsView.swift`.
 *
 * Its screens are pushed inside it by an internal `NavHost`, as the iPhone
 * pushes them inside the Settings tab's own `NavigationStack`: each tab keeps
 * its own stack, the system back gesture pops it, and leaving the tab and
 * coming back finds the same screen. "On this phone" is the one row that
 * leaves: it is the shell's to show, because the same list is also the app's
 * root while no server is connected.
 */

/** The screens Settings pushes. */
internal object SettingsRoutes {
    const val ROOT = "settings"
    const val CONTROLS = "settings/controls"
    const val READING = "settings/reading"
    const val DOWNLOADS = "settings/downloads"
    const val DIAGNOSTICS = "settings/diagnostics"
    const val FONTS = "settings/fonts"
    const val LICENCE = "settings/fonts/{id}"

    fun licence(id: String): String = "settings/fonts/$id"
}

/** The Settings tab: the list, and every screen it pushes. */
@Composable
fun SettingsScreen(onOpenLocalBooks: () -> Unit) {
    val environment = LocalAppEnvironment.current
    val navigation = rememberNavController()
    val back: () -> Unit = { navigation.popBackStack() }
    NavHost(
        navController = navigation,
        startDestination = SettingsRoutes.ROOT,
        // The iPhone's push: the new screen comes in from the trailing edge
        // over the old one, which drifts a third of the way back.
        enterTransition = { slideInHorizontally { it } },
        exitTransition = { slideOutHorizontally { -it / 3 } },
        popEnterTransition = { slideInHorizontally { -it / 3 } },
        popExitTransition = { slideOutHorizontally { it } },
    ) {
        composable(SettingsRoutes.ROOT) {
            SettingsRoot(environment, onNavigate = { navigation.navigate(it) }, onOpenLocalBooks = onOpenLocalBooks)
        }
        composable(SettingsRoutes.CONTROLS) { ControlsSettingsScreen(environment.settings, onBack = back) }
        composable(SettingsRoutes.READING) {
            ReadingSettingsScreen(environment.settings, onBack = back, onOpenLicences = { navigation.navigate(SettingsRoutes.FONTS) })
        }
        composable(SettingsRoutes.DOWNLOADS) { DownloadsScreen(environment.app, onBack = back) }
        composable(SettingsRoutes.DIAGNOSTICS) { DiagnosticsScreen(onBack = back) }
        composable(SettingsRoutes.FONTS) {
            FontLicencesScreen(onBack = back, onOpen = { navigation.navigate(SettingsRoutes.licence(it)) })
        }
        composable(SettingsRoutes.LICENCE) { entry ->
            LicenceTextScreen(entry.arguments?.getString("id").orEmpty(), onBack = back)
        }
    }
}

/** Who is signed in, where, and what that server offers: the Account rows and Advanced's. */
internal data class SettingsAccount(
    val username: String,
    val server: String,
    val capabilities: ServerCapabilities,
)

/** The account a signed-in session describes, or null while there is none. */
@Composable
internal fun rememberSettingsAccount(session: Session?): SettingsAccount? {
    session ?: return null
    val state by session.state.collectAsState()
    val capabilities by session.capabilities.collectAsState()
    val user = (state as? Session.State.SignedIn)?.user ?: return null
    return SettingsAccount(user.username ?: user.name ?: "—", session.serverUrl.toString(), capabilities)
}

/** The Settings list itself, reading the app's session. */
@Composable
internal fun SettingsRoot(environment: AppEnvironment, onNavigate: (String) -> Unit, onOpenLocalBooks: () -> Unit) {
    SettingsRootList(
        app = environment.app,
        settings = environment.settings,
        nowPlaying = environment.nowPlaying,
        local = environment.local,
        ask = environment.ask,
        account = rememberSettingsAccount(environment.app.session),
        onNavigate = onNavigate,
        onOpenLocalBooks = onOpenLocalBooks,
    )
}

/**
 * The list, given the account it describes.
 *
 * @param initiallyAdvanced whether Advanced starts expanded: a screenshot's.
 */
@Composable
internal fun SettingsRootList(
    app: AppModel,
    settings: PlaybackSettings,
    nowPlaying: NowPlayingController,
    local: LocalLibrary?,
    account: SettingsAccount?,
    onNavigate: (String) -> Unit,
    onOpenLocalBooks: () -> Unit,
    initiallyAdvanced: Boolean = false,
    ask: AskCoordinator? = null,
) {
    var advanced by rememberSaveable { mutableStateOf(initiallyAdvanced) }
    var confirmingSignOut by rememberSaveable { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    // For the app, not this screen: see `SignOutProgress`.
    val isSigningOut = SignOutProgress.shared.isRunning
    // What the bar under the player is measuring, said in the section that
    // sets it rather than left for the reader to discover in the car.
    val progressNote = if (settings.progressScope == ProgressScope.CHAPTER) {
        "The player, the lock screen and Android Auto all show the chapter you are in."
    } else {
        "The player, the lock screen and Android Auto all show the whole book."
    }

    SettingsPage(title = "Settings", onBack = null, listTag = "screen.settings") {
        if (account != null) {
            paperSection(key = "account", header = "Account") {
                row { LabeledRow("Signed in as", account.username) }
                row { LabeledRow("Server", account.server) }
            }
            paperSection(key = "library", header = "Library") {
                row { LabeledRow("Books", "${app.books.size}") }
                row { LabeledRow("With narration", "${app.derivation.readalongs.size}") }
            }
        }

        paperSection(key = "playback", header = "Playback & reading", footer = progressNote) {
            playbackRows(settings, onNavigate, includeDownloads = true)
        }

        // Between reading and the machinery, because that is what it is: a
        // reading feature, off by default, that most readers will decide about
        // once and never revisit.
        if (ask != null) askSettingsSection(ask)

        // Server internals and log export serve self-hosters and support, not
        // the general reader, so they collapse one tap down rather than
        // competing with Account / Library / Playback for attention.
        paperSection(key = "advanced") {
            row { AdvancedDisclosure(expanded = advanced, onToggle = { advanced = !advanced }) }
            if (advanced) advancedSettingsRows(account, local, onNavigate, onOpenLocalBooks)
        }

        paperSection(key = "signOut") {
            // Held off while one is under way. Signing out tells the server
            // first, and a server that does not answer is waited for up to the
            // logout's own limit — seconds in which nothing on this screen
            // changed and Sign out could be pressed again, starting a second
            // sign-out behind the first.
            row {
                ButtonRow(
                    if (isSigningOut) "Signing out…" else "Sign out",
                    onClick = { confirmingSignOut = true },
                    destructive = true,
                    enabled = !isSigningOut,
                )
            }
        }
    }

    if (confirmingSignOut) {
        fun signOut(keepDownloads: Boolean) {
            confirmingSignOut = false
            scope.launch {
                SignOutProgress.shared.run { app.signOut(keepDownloads = keepDownloads, nowPlaying = nowPlaying) }
            }
        }
        // Downloaded books are expensive to fetch again, so this is a choice
        // rather than an assumption.
        ChoiceDialog(
            title = "Sign out?",
            choices = listOf(
                DialogChoice("Sign out and keep downloads", enabled = !isSigningOut) { signOut(keepDownloads = true) },
                DialogChoice("Sign out and delete downloads", destructive = true, enabled = !isSigningOut) { signOut(keepDownloads = false) },
            ),
            onDismiss = { confirmingSignOut = false },
        )
    }
}

/**
 * Progress bar and the screens below it: the "Playback & reading" rows,
 * which the standalone settings sheet shows too, less Downloads & storage.
 */
internal fun PaperSectionScope.playbackRows(settings: PlaybackSettings, onNavigate: (String) -> Unit, includeDownloads: Boolean) {
    // Inline rather than a level down: it is one control, and the people who
    // want it are the ones staring at a five-hour bar wondering where their
    // chapter is.
    row {
        PickerRow(
            "Progress bar",
            selection = settings.progressScope,
            options = ProgressScope.entries,
            label = { it.title },
            onSelect = { settings.progressScope = it },
        )
    }
    row(dividerStart = IconRowDivider) {
        NavigationRow("Controls & remapping", { onNavigate(SettingsRoutes.CONTROLS) }, icon = Symbols.sliderHorizontal3)
    }
    row(dividerStart = IconRowDivider) {
        NavigationRow("Reading & highlights", { onNavigate(SettingsRoutes.READING) }, icon = Symbols.textformat)
    }
    if (includeDownloads) {
        row(dividerStart = IconRowDivider) {
            NavigationRow("Downloads & storage", { onNavigate(SettingsRoutes.DOWNLOADS) }, icon = Symbols.arrowDownCircle)
        }
    }
}

/** "Advanced": a disclosure that expands in place, its chevron in the accent turning down as it opens. */
@Composable
internal fun AdvancedDisclosure(expanded: Boolean, onToggle: () -> Unit) {
    val turn by animateFloatAsState(if (expanded) 90f else 0f, label = "disclosure")
    PaperRowFrame(
        modifier = Modifier.semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" },
        onClick = onToggle,
        role = Role.Button,
    ) {
        Text("Advanced", style = SystemText.body, color = Palette.ink, modifier = Modifier.weight(1f))
        Icon(
            painterResource(Symbols.chevronRight),
            contentDescription = null,
            tint = Palette.tangerine,
            modifier = Modifier.size(20.dp).rotate(turn),
        )
    }
}

/**
 * What "Advanced" holds: server capabilities, for self-hosters; the books on
 * this phone; and the log, for support. Swift's `AdvancedSettingsRows`.
 */
internal fun PaperSectionScope.advancedSettingsRows(
    account: SettingsAccount?,
    local: LocalLibrary?,
    onNavigate: (String) -> Unit,
    onOpenLocalBooks: () -> Unit,
) {
    if (account != null) {
        val capabilities = account.capabilities
        // Surfacing this makes it obvious which server generation is in play,
        // and why some rails are computed locally.
        row { OverlineRow("Server capabilities") }
        // The generation as detected, with the version the server reports
        // where it reports one — the first thing a self-hoster diagnosing "it
        // behaves differently since I upgraded" needs to see.
        row {
            LabeledRow(
                "Server version",
                capabilities.displayVersion,
                // The value is the row's state, so the live check reads the
                // plain version from it rather than parsing the merged label.
                Modifier
                    .testTag("settings.serverVersion")
                    .semantics(mergeDescendants = true) { stateDescription = capabilities.displayVersion },
            )
        }
        row { CapabilityRow("Home sections", capabilities.homeSections) }
        row { CapabilityRow("Shelves", capabilities.shelves) }
        row { CapabilityRow("Library facets", capabilities.libraryFacets) }
        row { CapabilityRow("Server discovery", capabilities.serverDiscovery) }
        row { FootnoteRow("Features your server does not provide are computed on this device instead.") }
    }
    if (local != null) localBooksRows(local, onOpenLocalBooks)
    row {
        NavigationRow(
            "Export logs",
            { onNavigate(SettingsRoutes.DIAGNOSTICS) },
            icon = Symbols.docTextMagnifyingglass,
        )
    }
}

/**
 * The way to the books added from the reader's files while a server is signed
 * in. Always here, also at zero books, so a signed-in reader can add one
 * without signing out; the count is shown only when there is one.
 */
private fun PaperSectionScope.localBooksRows(local: LocalLibrary, onOpenLocalBooks: () -> Unit) {
    row(dividerStart = IconRowDivider) {
        val count = local.books.size
        NavigationRow(
            LocalBooksCopy.listTitle,
            onOpenLocalBooks,
            modifier = Modifier.testTag("settings.localBooks"),
            icon = LocalDevice.symbol,
            value = if (count > 0) "$count" else null,
        )
    }
    row {
        FootnoteRow(
            "Books you add from ${LocalBooksCopy.ORIGINALS_PLACE} stay on this ${LocalDevice.noun}. " +
                "They aren’t sent to your server and don’t appear in Library.",
        )
    }
}

/** A capability and whether this server has it: a filled check in moss, or a quiet minus. */
@Composable
private fun CapabilityRow(name: String, available: Boolean) {
    PaperRowFrame(Modifier.semantics(mergeDescendants = true) { stateDescription = if (available) "Available" else "Not available" }) {
        TitleAndValue(
            title = { Text(name, style = SystemText.body, color = Palette.ink) },
            value = {
                Icon(
                    painterResource(if (available) Symbols.checkmarkCircleFill else Symbols.minusCircle),
                    contentDescription = null,
                    tint = if (available) Palette.moss else Palette.inkQuaternary,
                    modifier = Modifier.size(22.dp),
                )
            },
            modifier = Modifier.weight(1f),
        )
    }
}

/** The device's own glyph, for the Settings row: Swift's `LocalDevice.symbol`. */
val LocalDevice.symbol: Int get() = if (noun == "tablet") Symbols.ipad else Symbols.iphone
