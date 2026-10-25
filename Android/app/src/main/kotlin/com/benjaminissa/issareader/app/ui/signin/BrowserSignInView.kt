package com.benjaminissa.issareader.app.ui.signin

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.BrowserSignInModel
import com.benjaminissa.issareader.app.platform.AuthTabBrowser
import com.benjaminissa.issareader.ui.WrappingText
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Overline
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PrimaryButton
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.Typography

/**
 * Almost no chrome: the interesting screen is the server's, in the browser.
 * Swift's `BrowserSignInView`.
 *
 * Where this phone's browser cannot hand a sign-in back to the app — no
 * Chrome Auth Tab — the route says so and offers the device code, which needs
 * no browser here.
 *
 * @param onCancel back to the address, with what the form should say about
 *   why, when there is anything worth saying.
 * @param onUseDeviceCode straight to the pairing code, for a browser that
 *   cannot sign in.
 */
@Composable
fun BrowserSignInView(
    model: BrowserSignInModel,
    serverAddress: String,
    onGranted: (String) -> Unit,
    onCancel: (String?) -> Unit,
    onUseDeviceCode: () -> Unit,
) {
    // Starts one attempt, however often this appears; starting over is the
    // reader's "Try again".
    LaunchedEffect(model) { model.begin() }
    val stage = model.stage
    LaunchedEffect(stage) {
        when (stage) {
            is BrowserSignInModel.Stage.Granted -> onGranted(stage.token)
            is BrowserSignInModel.Stage.Dismissed -> onCancel(BrowserSignInModel.note(stage.by))
            else -> Unit
        }
    }
    val failed = stage is BrowserSignInModel.Stage.Failed || stage is BrowserSignInModel.Stage.UseDeviceCode
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing24)) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
            Overline("Sign in", color = Palette.tangerine)
            WrappingText(if (failed) "That didn't work." else "In your browser.", style = Typography.display, color = Palette.ink)
            Text(serverAddress, style = Typography.footnote.copy(fontFamily = FontFamily.Monospace), color = Palette.inkTertiary)
        }
        when (stage) {
            BrowserSignInModel.Stage.Starting -> StageRow("Opening your server's sign-in page…") {
                CircularProgressIndicator(color = Palette.inkTertiary, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
            }
            is BrowserSignInModel.Stage.Granted -> StageRow("Signed in.") {
                Icon(painterResource(Symbols.checkmarkCircleFill), contentDescription = null, tint = Palette.tangerine, modifier = Modifier.size(20.dp))
            }
            // On screen for an instant before the form comes back, but it
            // must not be a spinner.
            is BrowserSignInModel.Stage.Dismissed -> StageRow("Taking you back…") {}
            is BrowserSignInModel.Stage.Failed -> {
                Text(stage.reason, style = Typography.body, color = Palette.alert)
                Text(
                    "Try again",
                    style = Typography.body,
                    color = Palette.tangerine,
                    modifier = Modifier.clickable(role = Role.Button) { model.restart() },
                )
            }
            // This phone's browser cannot hand a sign-in back: say so, and
            // offer the way that needs no browser.
            BrowserSignInModel.Stage.UseDeviceCode -> {
                Text(AuthTabBrowser.UNSUPPORTED, style = Typography.body, color = Palette.alert)
                PrimaryButton("Use a device code", onClick = onUseDeviceCode)
            }
        }
        // Names its destination: there is one other way in, so say which.
        Text(
            "Use a device code instead",
            style = Typography.footnote,
            color = Palette.inkSecondary,
            modifier = Modifier
                .clickable(role = Role.Button) {
                    model.cancel()
                    onCancel(null)
                }
                .padding(vertical = Metrics.spacing4),
        )
    }
}

@Composable
private fun StageRow(text: String, leading: @Composable () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12)) {
        leading()
        Text(text, style = Typography.body, color = Palette.inkSecondary)
    }
}
