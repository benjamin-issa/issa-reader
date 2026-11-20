package com.benjaminissa.issareader.app.ui.settings

import android.content.ClipboardManager
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.ask.AskCoordinator
import com.benjaminissa.issareader.app.ask.AskDevice
import com.benjaminissa.issareader.ask.ProviderCatalog
import com.benjaminissa.issareader.ask.ProviderKind
import com.benjaminissa.issareader.ask.ProviderModel
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.ui.ButtonRow
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.NavigationRow
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperRowFrame
import com.benjaminissa.issareader.ui.PaperSectionScope
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.Typography
import com.benjaminissa.issareader.ui.WaitingIndicator
import com.benjaminissa.issareader.ui.paperSection
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/*
 * "Your own AI keys", in Settings › Advanced: Swift's `ProviderKeySetup.swift`.
 *
 * Advanced because it is for the few: a reader who has an Anthropic or OpenAI
 * account and wants Ask answered there. Nothing about Ask changes until a key
 * is added here — no picker, no new wording — and adding one goes through a
 * screen that says what will be sent, to whom, and on whose bill, with nothing
 * saved until the reader agrees.
 *
 * The key is held only in this screen's memory while it is being added: not
 * in saved instance state, which the system can write to disk.
 */

/** The rows in Advanced: one per provider, and what they are for. */
internal fun PaperSectionScope.providerKeyRows(coordinator: AskCoordinator, onNavigate: (String) -> Unit) {
    row { OverlineRow("Your own AI keys") }
    for (kind in ProviderKind.entries) {
        row(dividerStart = IconRowDivider) {
            NavigationRow(
                kind.displayName,
                { onNavigate(SettingsRoutes.aiKey(kind)) },
                modifier = Modifier.testTag("settings.aiKey.${kind.rawValue}"),
                icon = Symbols.key,
                value = coordinator.keys.registration(kind)?.model?.displayName ?: "Add key…",
            )
        }
    }
    row {
        FootnoteRow(
            "Use your own Anthropic or OpenAI account for “Ask about your book”. Questions go there only when you " +
                "choose it, and are billed to that account.",
        )
    }
}

/** One provider's key: how it is set up and the way to change it, or adding one. */
@Composable
internal fun ProviderKeyScreen(kind: ProviderKind, coordinator: AskCoordinator, onBack: () -> Unit, onChangeModel: () -> Unit) {
    var replacing by remember(kind) { mutableStateOf(false) }
    LaunchedEffect(kind) { coordinator.refreshKeys() }
    val registration = coordinator.keys.registration(kind)
    if (registration != null && !replacing) {
        ManageProviderKey(kind, registration.model, coordinator, onBack, onChangeModel, onReplace = { replacing = true })
    } else {
        AddProviderKey(kind, coordinator, onBack, onDone = { replacing = false })
    }
}

// Adding a key

/** Where adding a key has got to. Paste, check, choose a model, agree: nothing is saved before the last. */
private sealed interface AddStep {
    data object Enter : AddStep
    data object Checking : AddStep
    data class Choose(val models: List<ProviderModel>) : AddStep
    data class Consent(val model: ProviderModel) : AddStep
}

@Composable
private fun AddProviderKey(kind: ProviderKind, coordinator: AskCoordinator, onBack: () -> Unit, onDone: () -> Unit) {
    var key by remember(kind) { mutableStateOf("") }
    var step by remember(kind) { mutableStateOf<AddStep>(AddStep.Enter) }
    var problem by remember(kind) { mutableStateOf<String?>(null) }
    var chosen by remember(kind) { mutableStateOf<ProviderModel?>(null) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current

    fun check() {
        val candidate = key.trim()
        problem = null
        step = AddStep.Checking
        scope.launch {
            try {
                val models = coordinator.models(kind, candidate)
                chosen = models.firstOrNull { it.id == kind.preferredModelId } ?: models.firstOrNull()
                step = AddStep.Choose(models)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                problem = failure.catalogMessage(kind)
                step = AddStep.Enter
            }
        }
    }

    SettingsPage(title = kind.displayName, onBack = onBack, largeTitle = false, listTag = "screen.aiKey") {
        when (val current = step) {
            AddStep.Enter, AddStep.Checking -> paperSection(
                key = "aiKey.enter",
                footer = "${kind.keyInstructions} The key is kept on this ${AskDevice.noun} only.",
            ) {
                row { KeyField(key, onValueChange = { key = it }, onGo = { if (key.isNotBlank()) check() }) }
                row {
                    ButtonRow(
                        "Paste",
                        onClick = {
                            context.getSystemService(ClipboardManager::class.java)?.let { board ->
                                pasteKey(board)?.let { key = it }
                            }
                        },
                        modifier = Modifier.testTag("aiKey.paste"),
                    )
                }
                row {
                    if (current == AddStep.Checking) {
                        PaperRowFrame {
                            WaitingIndicator(color = Palette.tangerine, strokeWidth = 2.dp, size = 18.dp)
                            Text("Checking…", style = SystemText.body, color = Palette.inkTertiary)
                        }
                    } else {
                        ButtonRow(
                            "Check key",
                            onClick = ::check,
                            enabled = key.isNotBlank(),
                            modifier = Modifier.testTag("aiKey.check"),
                        )
                    }
                }
                problem?.let { sentence ->
                    row { FootnoteRow(sentence, Modifier.testTag("aiKey.problem"), color = Palette.ink) }
                }
            }
            is AddStep.Choose -> {
                modelList(kind, current.models, chosen, onChoose = { chosen = it })
                paperSection(key = "aiKey.continue") {
                    row {
                        ButtonRow(
                            "Continue",
                            onClick = { chosen?.let { step = AddStep.Consent(it) } },
                            enabled = chosen != null,
                            modifier = Modifier.testTag("aiKey.continue"),
                        )
                    }
                }
            }
            is AddStep.Consent -> paperSection(key = "aiKey.consent", header = "Before you add this key") {
                val model = current.model
                row {
                    ConsentText(
                        "Your questions, and the book you're reading up to your place, will be sent to " +
                            "${kind.displayName} to be answered by ${model.displayName}.",
                    )
                }
                row { ConsentText(kind.retentionSentence) }
                row {
                    ConsentText(
                        "Questions are billed to your ${kind.displayName} account. They go to ${kind.displayName} " +
                            "only when you choose it in Ask, or make it your default in Settings.",
                    )
                }
                row {
                    ButtonRow("${kind.displayName}'s privacy policy", onClick = { uriHandler.openUri(kind.privacyPolicyUrl) })
                }
                row {
                    ButtonRow(
                        "Agree and add key",
                        onClick = {
                            if (coordinator.registerKey(kind, key, model)) {
                                key = ""
                                step = AddStep.Enter
                                onDone()
                            } else {
                                problem = "The key couldn't be saved on this ${AskDevice.noun}. Try again."
                                step = AddStep.Enter
                            }
                        },
                        modifier = Modifier.testTag("aiKey.agree"),
                    )
                }
                row {
                    ButtonRow(
                        "Cancel",
                        onClick = {
                            key = ""
                            step = AddStep.Enter
                            onDone()
                        },
                        modifier = Modifier.testTag("aiKey.cancel"),
                    )
                }
            }
        }
    }
}

/**
 * Takes a key off the clipboard, and the clipboard's copy of it away: a key
 * left there is readable by the next app that is allowed to look.
 */
private fun pasteKey(board: ClipboardManager): String? {
    val text = try {
        board.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()?.trim()
    } catch (error: SecurityException) {
        IssaLog.info("ask key paste refused", mapOf("error" to error.javaClass.simpleName))
        null
    }
    if (text.isNullOrEmpty()) return null
    try {
        board.clearPrimaryClip()
    } catch (error: SecurityException) {
        IssaLog.info("ask key clipboard not cleared", mapOf("error" to error.javaClass.simpleName))
    }
    return text
}

/** The key, masked: the sign-in screen's plain field, with nothing a keyboard should learn. */
@Composable
private fun KeyField(value: String, onValueChange: (String) -> Unit, onGo: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    val shape = RoundedCornerShape(Metrics.radiusMedium)
    Box(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier.fillMaxWidth().testTag("aiKey.field").semantics { contentDescription = "API key" },
            textStyle = Typography.body.copy(color = Palette.ink),
            singleLine = true,
            cursorBrush = SolidColor(Palette.tangerine),
            interactionSource = interaction,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                keyboardType = KeyboardType.Password,
                imeAction = ImeAction.Go,
            ),
            keyboardActions = androidx.compose.foundation.text.KeyboardActions(onGo = { onGo() }),
            decorationBox = { field ->
                Box(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 44.dp)
                        .background(Palette.paper, shape)
                        .border(1.dp, if (focused) Palette.tangerine else Palette.border, shape)
                        .padding(horizontal = Metrics.spacing12),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    if (value.isEmpty()) Text("API key", style = Typography.body, color = Palette.inkTertiary, maxLines = 1)
                    field()
                }
            },
        )
    }
}

@Composable
private fun ConsentText(text: String) {
    PaperRowFrame { Text(text, style = SystemText.body, color = Palette.ink) }
}

// A key already added

@Composable
private fun ManageProviderKey(
    kind: ProviderKind,
    model: ProviderModel,
    coordinator: AskCoordinator,
    onBack: () -> Unit,
    onChangeModel: () -> Unit,
    onReplace: () -> Unit,
) {
    var confirmingRemoval by remember(kind) { mutableStateOf(false) }
    SettingsPage(title = kind.displayName, onBack = onBack, largeTitle = false, listTag = "screen.aiKey") {
        paperSection(
            key = "aiKey.manage",
            footer = "Questions you send to ${kind.displayName} go there with the book so far, billed to your account.",
        ) {
            row {
                NavigationRow("Model", onChangeModel, modifier = Modifier.testTag("aiKey.changeModel"), value = model.displayName)
            }
            row { ButtonRow("Replace key…", onClick = onReplace, modifier = Modifier.testTag("aiKey.replace")) }
        }
        // In place, not a dialog: the sentence and the two answers where the button was.
        paperSection(key = "aiKey.remove") {
            if (confirmingRemoval) {
                row {
                    ConsentText(
                        "Remove the ${kind.displayName} key from this ${AskDevice.noun}? Questions can't be sent to " +
                            "${kind.displayName} until you add one again.",
                    )
                }
                row {
                    ButtonRow(
                        "Remove key",
                        onClick = {
                            coordinator.removeKey(kind)
                            onBack()
                        },
                        destructive = true,
                        modifier = Modifier.testTag("aiKey.remove.confirm"),
                    )
                }
                row { ButtonRow("Keep it", onClick = { confirmingRemoval = false }, modifier = Modifier.testTag("aiKey.remove.keep")) }
            } else {
                row {
                    ButtonRow(
                        "Remove key…",
                        onClick = { confirmingRemoval = true },
                        destructive = true,
                        modifier = Modifier.testTag("aiKey.remove"),
                    )
                }
            }
        }
    }
}

/** The models the key can use, read again from the provider. */
@Composable
internal fun ChangeProviderModelScreen(kind: ProviderKind, coordinator: AskCoordinator, onBack: () -> Unit) {
    val current = coordinator.keys.registration(kind)?.model
    var models by remember(kind) { mutableStateOf<List<ProviderModel>?>(null) }
    var problem by remember(kind) { mutableStateOf<String?>(null) }
    var chosen by remember(kind) { mutableStateOf<ProviderModel?>(null) }
    LaunchedEffect(kind) {
        val key = coordinator.keys.key(kind)
        if (key == null) {
            problem = "The key for ${kind.displayName} isn't on this ${AskDevice.noun} any more."
            return@LaunchedEffect
        }
        try {
            val list = coordinator.models(kind, key)
            chosen = list.firstOrNull { it.id == current?.id }
            models = list
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            problem = failure.catalogMessage(kind)
        }
    }
    SettingsPage(title = "Model", onBack = onBack, largeTitle = false, listTag = "screen.aiKey.model") {
        val list = models
        when {
            list != null -> {
                modelList(kind, list, chosen, onChoose = { chosen = it })
                paperSection(key = "aiKey.useModel") {
                    row {
                        ButtonRow(
                            "Use this model",
                            onClick = {
                                chosen?.let { coordinator.chooseModel(kind, it) }
                                onBack()
                            },
                            enabled = chosen != null && chosen != current,
                            modifier = Modifier.testTag("aiKey.useModel"),
                        )
                    }
                }
            }
            problem != null -> paperSection(key = "aiKey.problem") { row { ConsentText(problem.orEmpty()) } }
            else -> paperSection(key = "aiKey.loading") {
                row {
                    PaperRowFrame { WaitingIndicator(color = Palette.tangerine, strokeWidth = 2.dp, size = 18.dp) }
                }
            }
        }
    }
}

/** The list a reader picks a model from: newest first, the preferred one first. */
private fun androidx.compose.foundation.lazy.LazyListScope.modelList(
    kind: ProviderKind,
    models: List<ProviderModel>,
    chosen: ProviderModel?,
    onChoose: (ProviderModel) -> Unit,
) {
    paperSection(
        key = "aiKey.models.${kind.rawValue}",
        header = "Models your key can use",
        footer = "Larger models answer better and cost more per question.",
    ) {
        for (model in models) {
            row {
                PaperRowFrame(
                    modifier = Modifier
                        .testTag("aiKey.model.${model.id}")
                        .semantics { selected = model == chosen },
                    onClick = { onChoose(model) },
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(model.displayName, style = SystemText.body, color = Palette.ink)
                    }
                    if (model == chosen) {
                        Icon(
                            painterResource(Symbols.checkmark),
                            contentDescription = null,
                            tint = Palette.tangerine,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }
            }
        }
    }
}

/** What went wrong reading a key's models, in the reader's words. */
private fun Exception.catalogMessage(kind: ProviderKind): String =
    (this as? ProviderCatalog.Failure)?.message(kind)
        ?: "Couldn't reach ${kind.displayName}. Check your connection and try again."
