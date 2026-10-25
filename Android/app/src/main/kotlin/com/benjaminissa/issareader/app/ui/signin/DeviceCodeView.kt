package com.benjaminissa.issareader.app.ui.signin

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.benjaminissa.issareader.app.model.Clipboard
import com.benjaminissa.issareader.app.model.DeviceSignInModel
import com.benjaminissa.issareader.core.auth.DeviceAuthorization
import com.benjaminissa.issareader.core.networking.isWebLink
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Overline
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Typography
import kotlinx.coroutines.delay
import java.time.Duration
import java.time.Instant

/**
 * The code to type, the address to open, and the QR to scan: Swift's
 * `DeviceCodeView`.
 *
 * The link and the QR both carry the server's `verification_uri_complete`, so
 * approving is one tap or one scan. That URL embeds the device code — the
 * polling secret — which was weighed and accepted (see
 * `DeviceAuthorization.approvalPayload`). The typeable code and address are
 * still shown, because the pre-filled route can always fail.
 */
@Composable
fun DeviceCodeView(model: DeviceSignInModel, onGranted: (String) -> Unit, onCancel: () -> Unit) {
    val stage = model.stage
    LaunchedEffect(stage) {
        if (stage is DeviceSignInModel.Stage.Granted) onGranted(stage.token)
    }
    DisposableEffect(model) { onDispose { model.cancel() } }
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing24)) {
        when (stage) {
            DeviceSignInModel.Stage.Starting -> Labelled("Contacting your server…")
            is DeviceSignInModel.Stage.AwaitingApproval -> Approval(model, stage.authorization, onCancel)
            is DeviceSignInModel.Stage.Granted -> Labelled("Signing in…")
            is DeviceSignInModel.Stage.Failed -> Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing12)) {
                Text("Couldn't sign in", style = Typography.title, color = Palette.ink)
                Text(stage.reason, style = Typography.footnote, color = Palette.inkSecondary)
                Text("Back", style = Typography.body, color = Palette.tangerine, modifier = Modifier.clickable(role = Role.Button, onClick = onCancel))
            }
        }
    }
}

/** A spinner over its label, as the system's labelled progress view draws one. */
@Composable
private fun Labelled(text: String) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        CircularProgressIndicator(color = Palette.inkTertiary, strokeWidth = 2.5.dp, modifier = Modifier.size(24.dp))
        Text(text, style = Typography.body, color = Palette.inkSecondary)
    }
}

@Composable
private fun Approval(model: DeviceSignInModel, auth: DeviceAuthorization, onCancel: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing24)) {
        Steps(auth)
        CodeBlock(auth)
        QrBlock(auth)
        AddressBlock(auth)
        StatusRow(model, onCancel)
    }
}

@Composable
private fun Steps(auth: DeviceAuthorization) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        Overline("Approve this device", color = Palette.tangerine)
        // Why anyone would be here rather than in a browser.
        Text("For a television, or when a browser can't open here.", style = Typography.subhead, color = Palette.inkSecondary)
        Step(1, buildAnnotatedString {
            append("Open ")
            withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(auth.verificationUri) }
            append(" on this device or another one.")
        })
        Step(2, buildAnnotatedString { append("Enter the code below if you are asked for one.") })
        Step(3, buildAnnotatedString { append("Approve this device.") })
    }
}

/** One numbered instruction. */
@Composable
private fun Step(number: Int, text: androidx.compose.ui.text.AnnotatedString) {
    Row(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        Text("$number.", style = Typography.headline.copy(fontFeatureSettings = "tnum"), color = Palette.tangerine)
        Text(text, style = Typography.callout, color = Palette.ink, modifier = Modifier.padding(top = 2.dp))
    }
}

/** The code, large and monospaced, and a tap that copies it. */
@Composable
private fun CodeBlock(auth: DeviceAuthorization) {
    val context = LocalContext.current
    var copiedAt by remember { mutableStateOf<Long?>(null) }
    LaunchedEffect(copiedAt) {
        if (copiedAt == null) return@LaunchedEffect
        delay(2_000)
        copiedAt = null
    }
    val shape = RoundedCornerShape(Metrics.radiusLarge)
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
        Text(
            auth.userCode,
            style = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, fontSize = 44.sp, letterSpacing = 4.sp),
            color = Palette.ink,
            textAlign = TextAlign.Center,
            maxLines = 1,
            modifier = Modifier
                .fillMaxWidth()
                .background(Palette.surface, shape)
                .border(1.dp, Palette.border, shape)
                .clickable(role = Role.Button, onClickLabel = "Copies the code") {
                    Clipboard.copy(context, auth.userCode)
                    copiedAt = System.nanoTime()
                }
                .semantics { contentDescription = auth.userCode.toList().joinToString(" ") }
                .padding(vertical = Metrics.spacing24),
        )
        Text(
            if (copiedAt == null) "Tap the code to copy it" else "Copied",
            style = Typography.footnote,
            color = if (copiedAt == null) Palette.inkTertiary else Palette.moss,
        )
    }
}

/** The QR, generated here: the server's is an SVG, and generating needs no network at all. */
@Composable
private fun QrBlock(auth: DeviceAuthorization) {
    val code = remember(auth.approvalPayload) { QrCode.encode(auth.approvalPayload) } ?: return
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        Text("Or scan this", style = Typography.footnote, color = Palette.inkTertiary)
        QrImage(
            code,
            Modifier
                .background(Color.White, RoundedCornerShape(Metrics.radiusSmall))
                .padding(Metrics.spacing8)
                .size(132.dp)
                .semantics { contentDescription = "QR code that opens the approval page for this device" },
        )
    }
}

/** The modules, square and unsmoothed, black on white. */
@Composable
fun QrImage(code: QrCode, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val module = size.width / code.size
        for (y in 0 until code.size) {
            for (x in 0 until code.size) {
                if (code[x, y]) drawRect(Color.Black, Offset(x * module, y * module), Size(module + 0.5f, module + 0.5f))
            }
        }
    }
}

/** The address, as a link: its label the plain address a person would type, its destination the pre-filled one. */
@Composable
private fun AddressBlock(auth: DeviceAuthorization) {
    val uriHandler = LocalUriHandler.current
    val url = auth.approvalUrl?.takeIf { it.isWebLink }
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
        Text("Or type the address", style = Typography.footnote, color = Palette.inkTertiary)
        Text(
            auth.verificationUri,
            style = Typography.body.copy(fontFamily = FontFamily.Monospace),
            color = Palette.tangerinePressed,
            modifier = if (url != null) {
                Modifier
                    .clickable(role = Role.Button) { uriHandler.openUri(url.toString()) }
                    .semantics { contentDescription = "Open ${auth.verificationUri} to approve this device" }
            } else {
                Modifier
            },
        )
    }
}

/**
 * What is happening, and how long this code has left. When it runs out the
 * model fetches another code in place, which this row also says.
 */
@Composable
private fun StatusRow(model: DeviceSignInModel, onCancel: () -> Unit) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(model) {
        while (true) {
            now = System.currentTimeMillis()
            delay(1_000)
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12)) {
        CircularProgressIndicator(color = Palette.inkTertiary, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
        val expiresAt = model.expiresAt
        val text = when {
            model.isRenewing -> "Getting a fresh code…"
            expiresAt != null && expiresAt.toEpochMilli() > now -> "Waiting for approval · ${countdown(Instant.ofEpochMilli(now), expiresAt)}"
            else -> "Waiting for approval…"
        }
        Text(text, style = Typography.footnote.copy(fontFeatureSettings = "tnum"), color = Palette.inkSecondary, modifier = Modifier.weight(1f))
        Text(
            "Use the browser instead",
            style = Typography.footnote,
            color = Palette.tangerine,
            modifier = Modifier.clickable(role = Role.Button, onClick = onCancel).padding(vertical = Metrics.spacing8),
        )
    }
}

/** "14:59", as a counting-down timer reads. */
fun countdown(now: Instant, until: Instant): String {
    val seconds = Duration.between(now, until).seconds.coerceAtLeast(0)
    val hours = seconds / 3600
    val minutes = (seconds % 3600) / 60
    val rest = seconds % 60
    return if (hours > 0) "%d:%02d:%02d".format(hours, minutes, rest) else "%d:%02d".format(minutes, rest)
}

