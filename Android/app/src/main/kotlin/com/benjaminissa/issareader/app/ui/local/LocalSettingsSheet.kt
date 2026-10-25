package com.benjaminissa.issareader.app.ui.local

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.systemBars
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import com.benjaminissa.issareader.app.local.LocalDevice
import com.benjaminissa.issareader.app.local.LocalLibrary
import com.benjaminissa.issareader.app.ui.settings.ControlsSettingsScreen
import com.benjaminissa.issareader.app.ui.settings.FontLicencesScreen
import com.benjaminissa.issareader.app.ui.settings.LicenceTextScreen
import com.benjaminissa.issareader.app.ui.settings.ReadingSettingsScreen
import com.benjaminissa.issareader.app.ui.settings.ScreenServices
import com.benjaminissa.issareader.app.ui.settings.SettingsPage
import com.benjaminissa.issareader.app.ui.settings.SettingsRoutes
import com.benjaminissa.issareader.app.ui.settings.playbackRows
import com.benjaminissa.issareader.core.model.ByteCountText
import com.benjaminissa.issareader.ui.ButtonRow
import com.benjaminissa.issareader.ui.LabeledRow
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.paperSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Settings for a reader with no server: the same groups, fewer rows.
 * `LocalSettingsSheet.swift`, as a full-height Material bottom sheet.
 *
 * Opened by the gear on the standalone list. Account, Library, Downloads &
 * storage, Ask and Advanced are left out — each needs a server. Playback &
 * reading is the same as everywhere else, and applies to the books on this
 * phone too. "On this phone" stands where Library would, and Server holds the
 * way back. Controls and Reading are pushed inside the sheet, as the iPhone
 * pushes them inside the sheet's own navigation stack.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LocalSettingsSheet(services: ScreenServices, library: LocalLibrary, onDismiss: () -> Unit, onConnectServer: () -> Unit) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Palette.paper,
        dragHandle = { BottomSheetDefaults.DragHandle(color = Palette.borderStrong) },
    ) {
        LocalSettingsContent(
            services = services,
            library = library,
            onDone = onDismiss,
            onConnectServer = {
                onDismiss()
                onConnectServer()
            },
            modifier = Modifier.fillMaxHeight().consumeWindowInsets(WindowInsets.systemBars.only(WindowInsetsSides.Top)),
        )
    }
}

/** The sheet's screens: its own list, and what that list pushes. */
@Composable
internal fun LocalSettingsContent(
    services: ScreenServices,
    library: LocalLibrary,
    onDone: () -> Unit,
    onConnectServer: () -> Unit,
    modifier: Modifier = Modifier,
    spaceUsed: Long? = null,
) {
    var stack by rememberSaveable { mutableStateOf(listOf(SettingsRoutes.ROOT)) }
    val push: (String) -> Unit = { stack = stack + it }
    val pop: () -> Unit = { stack = stack.dropLast(1) }
    BackHandler(enabled = stack.size > 1, onBack = pop)
    AnimatedContent(
        targetState = stack,
        modifier = modifier,
        transitionSpec = {
            if (targetState.size >= initialState.size) {
                slideInHorizontally { it } togetherWith slideOutHorizontally { -it / 3 }
            } else {
                slideInHorizontally { -it / 3 } togetherWith slideOutHorizontally { it }
            }
        },
        label = "localSettings",
    ) { screens ->
        val top = screens.last()
        when {
            top == SettingsRoutes.CONTROLS -> ControlsSettingsScreen(services.settings, onBack = pop, largeTitle = false)
            top == SettingsRoutes.READING ->
                ReadingSettingsScreen(services.settings, onBack = pop, onOpenLicences = { push(SettingsRoutes.FONTS) }, largeTitle = false)
            top == SettingsRoutes.FONTS -> FontLicencesScreen(onBack = pop, onOpen = { push(SettingsRoutes.licence(it)) })
            top.startsWith(SettingsRoutes.FONTS + "/") -> LicenceTextScreen(top.removePrefix(SettingsRoutes.FONTS + "/"), onBack = pop)
            else -> LocalSettingsRoot(services, library, onDone, onConnectServer, push, spaceUsed)
        }
    }
}

@Composable
private fun LocalSettingsRoot(
    services: ScreenServices,
    library: LocalLibrary,
    onDone: () -> Unit,
    onConnectServer: () -> Unit,
    onNavigate: (String) -> Unit,
    givenSpaceUsed: Long?,
) {
    var spaceUsed by remember { mutableStateOf(givenSpaceUsed) }
    if (givenSpaceUsed == null) {
        LaunchedEffect(library.books.map { it.uuid }) {
            val uuids = library.books.map { it.uuid }
            spaceUsed = withContext(Dispatchers.IO) { LocalLibrary.sizes(uuids, library.root).values.sum() }
        }
    }
    SettingsPage(
        title = "Settings",
        onBack = null,
        largeTitle = false,
        listTag = "screen.localSettings",
        actions = {
            TextButton(onClick = onDone) {
                Text("Done", style = SystemText.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.tangerine)
            }
        },
    ) {
        paperSection(key = "device", header = "On this ${LocalDevice.noun}") {
            row { LabeledRow("Books", "${library.books.size}") }
            row { LabeledRow("Space used", spaceUsed?.let(ByteCountText::text) ?: "—") }
        }
        paperSection(key = "playback", header = "Playback & reading") {
            playbackRows(services.settings, onNavigate, includeDownloads = false)
        }
        paperSection(
            key = "server",
            header = "Server",
            footer = "Library, sync, downloads and Ask about your book need a server. Books on this ${LocalDevice.noun} stay here either way.",
        ) {
            row {
                ButtonRow(
                    "Connect to a Storyteller server",
                    onClick = onConnectServer,
                    modifier = Modifier.testTag("settings.connectToServer"),
                )
            }
        }
        paperSection(key = "about", header = "About") {
            row { LabeledRow("Version", services.versionText) }
        }
    }
}
