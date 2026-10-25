package com.benjaminissa.issareader.app.ui.settings

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.ui.IssaFonts
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperRowFrame
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.Typography
import com.benjaminissa.issareader.ui.paperSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Who made what the app ships, and under what terms: `FontLicencesView.swift`.
 *
 * The SIL Open Font License asks that it travel with the font software; each
 * family's own licence is an asset beside the faces, and this is where a
 * reader can actually read one. Android adds two groups the iPhone has no use
 * for: the icons, which are Google's Material Symbols rather than Apple's SF
 * Symbols, and the libraries the Android app is built on.
 */
@Composable
internal fun FontLicencesScreen(onBack: (() -> Unit)?, onOpen: (String) -> Unit) {
    val context = LocalContext.current
    SettingsPage(title = "Fonts & licences", onBack = onBack, largeTitle = false) {
        paperSection(
            key = "faces",
            header = "Bundled faces",
            footer = "Every face the app ships is under the SIL Open Font License 1.1. Fonts you import yourself are governed by their own terms.",
        ) {
            for (licence in Licences.faces) {
                row { LicenceRow(licence.title, remember(licence.id) { licence.subtitle(context) }, onClick = { onOpen(licence.id) }) }
            }
        }
        paperSection(key = "icons", header = "Icons", footer = "The app’s icons are Material Symbols, by Google.") {
            for (licence in Licences.icons) {
                row { LicenceRow(licence.title, remember(licence.id) { licence.subtitle(context) }, onClick = { onOpen(licence.id) }) }
            }
        }
        paperSection(key = "libraries", header = "Libraries", footer = "The Android app is built on these, each used under the terms it names.") {
            for (licence in Licences.libraries) {
                row { LicenceRow(licence.title, remember(licence.id) { licence.subtitle(context) }, onClick = { onOpen(licence.id) }) }
            }
        }
    }
}

/** One licence: its name, and the first line of its terms under it. */
@Composable
private fun LicenceRow(title: String, subtitle: String, onClick: () -> Unit) {
    PaperRowFrame(onClick = onClick) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Typography.body, color = Palette.ink)
            Text(subtitle, style = Typography.caption, color = Palette.inkTertiary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Icon(painterResource(Symbols.chevronRight), contentDescription = null, tint = Palette.inkQuaternary, modifier = Modifier.size(20.dp))
    }
}

/** One licence's full text, selectable, under its name. */
@Composable
internal fun LicenceTextScreen(id: String, onBack: (() -> Unit)?) {
    val context = LocalContext.current
    val licence = remember(id) { Licences.all.firstOrNull { it.id == id } }
    val text by produceState<String?>(null, licence) {
        value = withContext(Dispatchers.IO) { licence?.text(context) } ?: "Licence text unavailable."
    }
    SettingsPage(title = licence?.title ?: "Licence", onBack = onBack, largeTitle = false) {
        item(key = "text") {
            SelectionContainer {
                Text(
                    text.orEmpty(),
                    style = Typography.caption.copy(fontFamily = FontFamily.Monospace),
                    color = Palette.inkSecondary,
                    modifier = Modifier.fillMaxWidth().padding(Metrics.spacing16),
                )
            }
        }
    }
}

/** Everything the licences screen lists, and where each text is. */
internal object Licences {
    /** One licence: an id to push by, a name, and how to read its terms. */
    class Licence(
        val id: String,
        val title: String,
        /** The asset holding the licence itself. */
        private val asset: String,
        /** A second asset appended to it: the Apache License's full text after a library's notice. */
        private val appended: String? = null,
        /** Said under the name when the asset's first line is not the copyright. */
        private val fixedSubtitle: String? = null,
    ) {
        fun text(context: Context): String? {
            val own = read(context, asset) ?: return null
            val more = appended?.let { read(context, it) } ?: return own
            return own.trimEnd() + "\n\n" + more
        }

        /**
         * The first line of the licence, which is the copyright statement in
         * every OFL file. Read from the file rather than restated here, so the
         * two cannot disagree.
         */
        fun subtitle(context: Context): String = fixedSubtitle
            ?: read(context, asset)?.lineSequence()?.firstOrNull { it.isNotBlank() }?.trim()
            ?: "SIL Open Font License 1.1"

        private fun read(context: Context, name: String): String? =
            runCatching { context.assets.open(name).bufferedReader().use { it.readText() } }.getOrNull()
    }

    private const val APACHE = "Licences/MaterialSymbols-Apache-2.0.txt"

    val faces: List<Licence> = IssaFonts.allFaces.map { face ->
        Licence(id = "font-" + face.family.lowercase().replace(' ', '-'), title = face.title, asset = face.licenceAsset)
    }

    val icons: List<Licence> = listOf(
        Licence("material-symbols", "Material Symbols", APACHE, fixedSubtitle = "Google · Apache License 2.0"),
    )

    val libraries: List<Licence> = listOf(
        Licence("androidx", "AndroidX", "Licences/AndroidX-NOTICE.txt", APACHE, fixedSubtitle = "The Android Open Source Project · Apache License 2.0"),
        Licence("media3", "Media3", "Licences/Media3-NOTICE.txt", APACHE, fixedSubtitle = "The Android Open Source Project · Apache License 2.0"),
        Licence("okhttp", "OkHttp and Okio", "Licences/OkHttp-NOTICE.txt", APACHE, fixedSubtitle = "Square, Inc. · Apache License 2.0"),
        Licence("kotlinx", "Kotlin and kotlinx", "Licences/Kotlinx-NOTICE.txt", APACHE, fixedSubtitle = "JetBrains s.r.o. · Apache License 2.0"),
        Licence("mlkit", "ML Kit", "Licences/MLKit-NOTICE.txt", fixedSubtitle = "Google · ML Kit Terms of Service"),
    )

    val all: List<Licence> get() = faces + icons + libraries
}
