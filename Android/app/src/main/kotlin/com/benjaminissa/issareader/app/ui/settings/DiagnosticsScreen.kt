package com.benjaminissa.issareader.app.ui.settings

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.core.content.FileProvider
import com.benjaminissa.issareader.app.model.Clipboard
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.ui.ButtonRow
import com.benjaminissa.issareader.ui.LabeledRow
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperRowContent
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.Typography
import com.benjaminissa.issareader.ui.paperSection
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Handing over what happened, when something goes wrong in a beta:
 * `DiagnosticsView.swift`.
 *
 * The log is the app's own file, so the launch worth reporting — usually the
 * one before the one being looked at — is in it.
 *
 * @param preview the log's tail and its entry count, given rather than read:
 *   a screenshot's.
 */
@Composable
internal fun DiagnosticsScreen(onBack: (() -> Unit)?, preview: Pair<String, Int>? = null) {
    val context = LocalContext.current
    var text by remember { mutableStateOf(preview?.first ?: "") }
    var entryCount by remember { mutableIntStateOf(preview?.second ?: 0) }
    var confirmingClear by remember { mutableStateOf(false) }
    var revision by remember { mutableIntStateOf(0) }

    if (preview == null) {
        LaunchedEffect(revision) {
            val (tail, count) = withContext(Dispatchers.IO) { Diagnostics.read() }
            text = tail
            entryCount = count
        }
    }
    // The export is a full copy of the log on disk, made for the share sheet
    // and not meant to outlive the screen.
    DisposableEffect(Unit) { onDispose { Diagnostics.discardExports(context) } }

    SettingsPage(title = "Diagnostics", onBack = onBack) {
        paperSection(key = "intro") {
            row { PaperRowContent { Text(Diagnostics.INTRO, style = Typography.footnote, color = Palette.inkSecondary) } }
        }
        paperSection(key = "recorded", header = "Recorded") {
            row { LabeledRow("Entries", "$entryCount") }
            row { LabeledRow("Covering", "Last 6 hours") }
        }
        // Said before anything is shared, not after: what the file contains is
        // the reader's decision to make.
        paperSection(key = "export", footer = "The file names your server and the books you opened. Sign-in codes and access tokens are never recorded.") {
            row(dividerStart = IconRowDivider) {
                ButtonRow("Export logs", onClick = { Diagnostics.share(context) }, icon = Symbols.squareAndArrowUp)
            }
            row {
                ButtonRow("Copy to clipboard", onClick = { Clipboard.copy(context, IssaLog.export()) }, icon = Symbols.docOnDoc)
            }
        }
        paperSection(key = "recent", header = "Most recent") {
            row {
                PaperRowContent {
                    SelectionContainer {
                        Text(
                            text.ifEmpty { "Nothing recorded yet." },
                            style = SystemText.caption1.copy(fontFamily = FontFamily.Monospace),
                            color = Palette.inkSecondary,
                        )
                    }
                }
            }
        }
        paperSection(key = "clear") {
            row { ButtonRow("Clear log", onClick = { confirmingClear = true }, destructive = true) }
        }
    }

    if (confirmingClear) {
        AlertDialog(
            onDismissRequest = { confirmingClear = false },
            containerColor = Palette.surface,
            title = { Text("Clear the log?", style = SystemText.title3.copy(fontWeight = FontWeight.SemiBold), color = Palette.ink) },
            confirmButton = {
                TextButton(onClick = {
                    confirmingClear = false
                    IssaLog.clear()
                    revision += 1
                }) { Text("Clear", style = SystemText.subheadline.copy(fontWeight = FontWeight.SemiBold), color = dialogButtonColor(destructive = true)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingClear = false }) {
                    Text("Cancel", style = SystemText.subheadline.copy(fontWeight = FontWeight.SemiBold), color = dialogButtonColor(destructive = false))
                }
            },
        )
    }
}

/** Reading, exporting and sharing the log. */
internal object Diagnostics {
    const val INTRO = "Issa Reader keeps a record of what it did for the last six hours. If something goes wrong, export it and send it on."

    /** The FileProvider's authority (`AndroidManifest.xml`) and the cache folder it serves (`file_paths.xml`). */
    private fun authority(context: Context): String = "${context.packageName}.files"

    private fun exportsDirectory(context: Context): File = File(context.cacheDir, "exports")

    /** The last twelve lines — what just went wrong is at the end — and how many entries there are. */
    fun read(): Pair<String, Int> {
        val count = IssaLog.count()
        val tail = IssaLog.export().split("\n").filter { it.isNotEmpty() }.takeLast(12).joinToString("\n")
        return tail to count
    }

    /**
     * Writes the export and hands it to the share sheet as a file. Written on
     * the tap rather than when the screen opens, so merely looking at this
     * screen leaves six hours of hostnames and book titles on disk nowhere.
     */
    fun share(context: Context) {
        val file = export(context) ?: return
        val uri = runCatching { FileProvider.getUriForFile(context, authority(context), file) }.getOrNull() ?: return
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, "Issa Reader diagnostics")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(send, "Export logs").apply {
            if (context !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        runCatching { context.startActivity(chooser) }
            .onFailure { IssaLog.warning("log export could not be shared", mapOf("error" to it.toString())) }
    }

    /**
     * The log's export, moved into the folder the FileProvider serves. The
     * core writes it beside the other temporary files; only `cache/exports/`
     * is offered to other apps.
     */
    fun export(context: Context): File? {
        val written = IssaLog.exportFile() ?: return null
        val directory = exportsDirectory(context)
        directory.deleteRecursively()
        directory.mkdirs()
        val destination = File(directory, written.name)
        val moved = written.renameTo(destination) || runCatching { written.copyTo(destination, overwrite = true); written.delete() }.isSuccess
        return if (moved) destination else null
    }

    /** Removes every export written for sharing. */
    fun discardExports(context: Context) {
        IssaLog.discardExports()
        exportsDirectory(context).deleteRecursively()
    }
}
