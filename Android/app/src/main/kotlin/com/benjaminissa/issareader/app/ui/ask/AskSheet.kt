package com.benjaminissa.issareader.app.ui.ask

import android.content.Context
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.benjaminissa.issareader.app.ui.reader.ReaderSheet
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Typography

/*
 * PLACEHOLDER. The Ask port replaces this whole file with the real sheet
 * (Swift's `AskSheet`, `AskPanel`, `AskCoordinator`) and the real
 * availability check (Swift's `AskAvailability`, here Gemini Nano through ML
 * Kit). The reader only calls the two entry points below, with these
 * signatures: the sparkle in its top bar is drawn when
 * `settings.askEnabled && AskAvailability.offersAsk(context)`, and tapping it
 * shows `AskSheet(bookUuid, onDismiss)`.
 */

/** Whether this device can answer questions. */
object AskAvailability {
    /**
     * Whether the reader offers Ask at all, on top of the setting: the iPhone
     * shows it while the model is available, switched off or still
     * downloading, and hides it on hardware that will never run it.
     *
     * Placeholder: offers it wherever the setting is on, until the Ask port
     * asks the on-device model.
     */
    @Suppress("UNUSED_PARAMETER")
    fun offersAsk(context: Context): Boolean = true
}

/** The Ask sheet over the reader. Placeholder: the Ask port replaces it. */
@Suppress("UNUSED_PARAMETER")
@Composable
fun AskSheet(bookUuid: String, onDismiss: () -> Unit) {
    ReaderSheet(onDismiss = onDismiss, halfHeight = true) { _ ->
        Column(Modifier.fillMaxWidth().padding(Metrics.spacing24)) {
            Text("Ask about this book", style = Typography.headline, color = Palette.ink)
        }
    }
}
