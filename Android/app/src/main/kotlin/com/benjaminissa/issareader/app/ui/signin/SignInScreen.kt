package com.benjaminissa.issareader.app.ui.signin

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.BrowserSignInModel
import com.benjaminissa.issareader.app.model.DeviceSignInModel
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Overline
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PrimaryButton
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.Typography
import kotlinx.coroutines.launch
import java.net.URI

/**
 * Server address, then how to sign in: Swift's `SignInView`.
 *
 * Two routes, both ending in `AppModel.adopt`. The browser is the answer for
 * nearly everyone: the server's own sign-in page offers a password and every
 * identity provider its operator configured, and hands a token straight
 * back. The device code stays for when a browser cannot hand a sign-in back.
 * The client never implements an OIDC client and names no provider.
 *
 * One screen for every signed-out phase, the session-ended notice included, so
 * the screen a tap started in is the one still showing when its work ends.
 *
 * @param onReadFromFiles the books-from-your-files link, shown only where that
 *   flow exists.
 */
@Composable
fun SignInScreen(onReadFromFiles: (() -> Unit)? = null, onStartingSignIn: () -> Unit = {}) {
    val environment = LocalAppEnvironment.current
    val app = environment.app
    var route by remember { mutableStateOf<SignInRoute>(SignInRoute.Address) }
    var address by rememberSaveable { mutableStateOf("") }
    var connecting by remember { mutableStateOf(false) }
    // Why the reader is back here when the browser route ended without a
    // token or an error — a real outcome that used to render as nothing.
    var signInNote by rememberSaveable { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) { if (address.isEmpty()) address = app.serverAddress }

    // The URL the session is actually talking to, not a re-derivation of the
    // text: `connect` resolves a bare hostname by probing.
    fun serverUrl(): URI? = app.session?.serverUrl ?: AppModel.normalizeServerUrl(app.serverAddress)

    // Run on the app's scope, as Swift's unstructured `Task` is: a successful
    // sign-in replaces this screen, and its work must not die with it.
    fun startSignIn(destination: SignInDestination) {
        app.scope.launch {
            connecting = true
            try {
                signInNote = null
                // A sign-in the reader started is the screen they asked for.
                onStartingSignIn()
                if (address.isEmpty()) address = app.serverAddress
                app.connect(address)
                // A stored token may have signed us straight in.
                if (app.phase == AppModel.Phase.READY) return@launch
                val url = serverUrl() ?: return@launch
                // Only when the connect actually succeeded: its early returns
                // leave the previous session in place.
                if (app.loadError != null) return@launch
                when (destination) {
                    SignInDestination.BROWSER -> route = SignInRoute.Browser(environment.browserSignIn(url))
                    SignInDestination.DEVICE_CODE -> {
                        val model = environment.deviceSignIn(url)
                        route = SignInRoute.Pairing(model)
                        model.begin()
                    }
                }
            } finally {
                connecting = false
            }
        }
    }

    /** The flow the token came from is stopped once it has handed one over. */
    fun adopt(token: String, browser: BrowserSignInModel? = null) {
        app.scope.launch {
            app.adopt(token)
            browser?.cancel()
            // Only when it did not work: a successful adopt ends at READY and
            // the root swaps this whole screen out.
            if (app.phase != AppModel.Phase.READY) route = SignInRoute.Address
        }
    }

    val serverLabel = serverUrl()?.toString() ?: app.serverAddress
    SignInFrame {
        val current = route
        if (app.phase == AppModel.Phase.EXPIRED && current is SignInRoute.Address) {
            ExpiredNotice(app.serverAddress, onSignInAgain = { startSignIn(SignInDestination.BROWSER) }, onReadFromFiles = onReadFromFiles)
            return@SignInFrame
        }
        when (current) {
            SignInRoute.Address -> ServerForm(
                address = address,
                onAddressChange = { address = it },
                loadError = app.loadError,
                signInNote = signInNote,
                connecting = connecting,
                onContinue = { startSignIn(SignInDestination.BROWSER) },
                onDeviceCode = { startSignIn(SignInDestination.DEVICE_CODE) },
                onReadFromFiles = onReadFromFiles,
            )
            is SignInRoute.Browser -> BrowserSignInView(
                model = current.model,
                serverAddress = serverLabel,
                onGranted = { token -> adopt(token, current.model) },
                onCancel = { note ->
                    // Cancelled here, where the route is actually left.
                    current.model.cancel()
                    signInNote = note
                    route = SignInRoute.Address
                },
                onUseDeviceCode = {
                    current.model.cancel()
                    startSignIn(SignInDestination.DEVICE_CODE)
                },
            )
            is SignInRoute.Pairing -> DeviceCodeView(
                model = current.model,
                onGranted = { token -> adopt(token) },
                onCancel = {
                    current.model.cancel()
                    route = SignInRoute.Address
                },
            )
        }
    }
}

/** Where the reader is, carrying the model that route needs. */
private sealed interface SignInRoute {
    data object Address : SignInRoute
    data class Browser(val model: BrowserSignInModel) : SignInRoute
    data class Pairing(val model: DeviceSignInModel) : SignInRoute
}

/** Which way in a tap asked for; neither can be entered without a resolved server. */
private enum class SignInDestination { BROWSER, DEVICE_CODE }

/**
 * Whether the address in the field would be spoken to in the clear. A bare
 * address counts: what a LAN server answers on is plain HTTP, and the field's
 * own hint suggests exactly that form.
 */
fun isCleartext(typed: String): Boolean = AppModel.normalizeServerUrl(typed)?.scheme?.lowercase() == "http"

/**
 * The paper, and the content at most 460 wide, 32 in from the edges, centred
 * in the height when it fits and scrolling when it does not — the device
 * code's screen is taller than a small phone.
 */
@Composable
private fun SignInFrame(content: @Composable () -> Unit) {
    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(Palette.paper)
            .testTag("screen.signIn")
            .safeDrawingPadding()
            .imePadding(),
    ) {
        val viewport = maxHeight
        Box(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
            contentAlignment = Alignment.TopCenter,
        ) {
            Box(
                Modifier
                    .heightIn(min = viewport)
                    .widthIn(max = 460.dp)
                    .fillMaxWidth()
                    .padding(Metrics.spacing32)
                    .testTag("content.signIn"),
                contentAlignment = Alignment.CenterStart,
            ) {
                content()
            }
        }
    }
}

/** Shown when a token has gone stale, rather than dropping the reader back to a blank field. */
@Composable
private fun ExpiredNotice(server: String, onSignInAgain: () -> Unit, onReadFromFiles: (() -> Unit)?) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing24)) {
        Overline("Signed out", color = Palette.tangerine)
        Text("Your session has ended.", style = Typography.displayLarge, color = Palette.ink)
        Text(
            "Sessions last about a month. Your library and downloads are still here — sign in again to carry on.",
            style = Typography.body,
            color = Palette.inkSecondary,
        )
        Text(server, style = Typography.body.copy(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace), color = Palette.inkTertiary)
        PrimaryButton("Sign in again", onSignInAgain, Modifier.testTag("button.signInAgain"))
        if (onReadFromFiles != null) {
            QuietLink("Read a book from your files", enabled = true, onClick = onReadFromFiles, modifier = Modifier.testTag("link.readFromFiles"))
        }
    }
}

@Composable
private fun ServerForm(
    address: String,
    onAddressChange: (String) -> Unit,
    loadError: String?,
    signInNote: String?,
    connecting: Boolean,
    onContinue: () -> Unit,
    onDeviceCode: () -> Unit,
    onReadFromFiles: (() -> Unit)?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing24)) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
            Overline("Issa Reader", color = Palette.tangerine)
            Text("Welcome back.", style = Typography.displayLarge, color = Palette.ink)
            Text("Connect to your server and pick up exactly where the narrator left off.", style = Typography.body, color = Palette.inkSecondary)
        }
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
            Overline("Server")
            ServerField(address, onAddressChange, onGo = { if (address.isNotEmpty() && !connecting) onContinue() })
            Text(
                "Your library's web address. On your own network it might look like 192.168.1.10:8001.",
                style = Typography.footnote,
                color = Palette.inkTertiary,
            )
            // From the field, not from the session: the fact is about the
            // address being typed.
            if (isCleartext(address)) {
                Text("Not encrypted — this server is on http://.", style = Typography.footnote, color = Palette.alert)
            }
        }
        // The server's answer, then this attempt's: two slots, because they
        // say different things.
        if (loadError != null) Text(loadError, style = Typography.footnote, color = Palette.alert)
        if (signInNote != null) Text(signInNote, style = Typography.footnote, color = Palette.inkSecondary)

        Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing8 + 2.dp)) {
            PrimaryButton(
                if (connecting) "Connecting…" else "Continue in browser",
                onClick = onContinue,
                enabled = address.isNotEmpty() && !connecting,
                working = connecting,
                trailingIcon = Symbols.arrowUpRight,
            )
            Text(
                "Your library's own sign-in page opens, then you land back here.",
                style = Typography.footnote,
                color = Palette.inkTertiary,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(Palette.border))
        // The two quiet links touch: two 44-point targets, one above the
        // other, neither competing with the button.
        Column {
            QuietLink("Use a device code", enabled = address.isNotEmpty() && !connecting, onClick = onDeviceCode)
            if (onReadFromFiles != null) {
                QuietLink("Read a book from your files", enabled = true, onClick = onReadFromFiles, modifier = Modifier.testTag("link.readFromFiles"))
            }
        }
    }
}

/**
 * The address field: Material's outlined field in the palette — the surface
 * fill, the medium radius, the accent when focused — with the example address
 * as its placeholder and no autocorrection.
 */
@Composable
private fun ServerField(value: String, onValueChange: (String) -> Unit, onGo: () -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth().testTag("field.serverAddress").semantics { contentDescription = "Server" },
        textStyle = Typography.body,
        placeholder = { Text("https://yourlibrary.com", style = Typography.body, color = Palette.inkTertiary) },
        singleLine = true,
        shape = RoundedCornerShape(Metrics.radiusMedium),
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            autoCorrectEnabled = false,
            keyboardType = KeyboardType.Uri,
            imeAction = ImeAction.Go,
        ),
        keyboardActions = KeyboardActions(onGo = { onGo() }),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = Palette.ink,
            unfocusedTextColor = Palette.ink,
            focusedContainerColor = Palette.surface,
            unfocusedContainerColor = Palette.surface,
            focusedBorderColor = Palette.tangerine,
            unfocusedBorderColor = Palette.border,
            cursorColor = Palette.tangerine,
        ),
    )
}

/**
 * A link rather than a button, still a full-width 44-point target: the quiet
 * underlined line under the separator.
 */
@Composable
internal fun QuietLink(title: String, enabled: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val underline = Palette.borderStrong
    Box(
        modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            title,
            style = Typography.subhead.copy(fontWeight = FontWeight.Medium),
            color = Palette.inkTertiary,
            modifier = Modifier
                .alpha(if (enabled) 1f else 0.55f)
                .drawBehind {
                    val y = size.height - 1.dp.toPx()
                    drawLine(underline, Offset(0f, y), Offset(size.width, y), strokeWidth = 1.dp.toPx())
                },
        )
    }
}

