package com.benjaminissa.issareader.app.ui.ask

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.ask.AskCoordinator
import com.benjaminissa.issareader.app.ask.AskDefaults
import com.benjaminissa.issareader.app.ask.AskDevice
import com.benjaminissa.issareader.app.ask.AskJob
import com.benjaminissa.issareader.app.model.Clipboard
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.ask.AskAnswer
import com.benjaminissa.issareader.ask.AskAnswerer
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ask.AskSource
import com.benjaminissa.issareader.ask.AskSuggestions
import com.benjaminissa.issareader.ask.Passage
import com.benjaminissa.issareader.ui.BetaPill
import com.benjaminissa.issareader.ui.EInk
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperMenu
import com.benjaminissa.issareader.ui.PaperSheet
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.Typography
import com.benjaminissa.issareader.ui.WaitingIndicator
import kotlinx.coroutines.launch

/**
 * One question, one answer, nothing kept: the sheet the reader's sparkle
 * opens, for the book on screen, with the app's [AskCoordinator] from the
 * reader's environment. [onDismiss] is called once, however the sheet goes.
 *
 *
 * Four states in one sheet rather than four screens, because they are one
 * thought: the reader asks, waits, reads, and either asks again or closes. A
 * navigation stack between them would put a Back button on a conversation that
 * has nowhere to go back to.
 *
 * Done always dismisses, and a working job carries on behind it — which is the
 * point of the whole job model, and the reason the footer says so in words.
 *
 * Material's bottom sheet in the palette, half the screen high first so the
 * page the question is about stays visible behind it, growing to the full
 * height only when an answer genuinely needs the room — the iPhone's medium
 * and large detents.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AskSheet(model: ReaderModel, coordinator: AskCoordinator, onDismiss: () -> Unit) {
    val uuid = model.book.uuid
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    val scope = rememberCoroutineScope()
    var large by remember(uuid) { mutableStateOf(false) }
    var closed by remember(uuid) { mutableStateOf(false) }

    fun close() {
        if (closed) return
        closed = true
        coordinator.sheetDismissed(uuid)
        onDismiss()
    }

    fun dismiss() {
        scope.launch { sheetState.hide() }.invokeOnCompletion { close() }
    }

    // The permission to notify, put the first time a question is asked: the
    // coordinator decides when, and only a screen can ask.
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        coordinator.notificationPermissionAsked()
    }
    val wantsPermission = coordinator.wantsNotificationPermission
    LaunchedEffect(wantsPermission) {
        if (!wantsPermission) return@LaunchedEffect
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permission.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            coordinator.notificationPermissionAsked()
        }
    }

    PaperSheet(
        onDismissRequest = ::close,
        sheetState = sheetState,
        contentColor = Palette.ink,
        dragHandle = { SheetGrabber() },
    ) {
        AskSheetBody(
            model = model,
            coordinator = coordinator,
            height = if (large) null else LocalConfiguration.current.screenHeightDp.dp * MEDIUM_FRACTION,
            onContentHeight = { height ->
                // A little slack: the detent is about whether the answer fits,
                // not about the last two points of a footer.
                if (height > LARGE_THRESHOLD) large = true
            },
            onDone = ::dismiss,
            onOpenSource = { passage ->
                // A departure rather than a detour: closing discards the
                // answer, so the passage is read out before the sheet goes.
                dismiss()
                coordinator.openInTheBook(model, passage)
            },
        )
    }
}

/** The iPhone's medium detent: half the screen. */
private const val MEDIUM_FRACTION = 0.5f

/** Taller than this and an answer opens the sheet to its full height. */
private val LARGE_THRESHOLD = 300.dp

/** The sheet's own state, between the coordinator and the drawing. */
@Composable
private fun AskSheetBody(
    model: ReaderModel,
    coordinator: AskCoordinator,
    height: Dp?,
    onContentHeight: (Dp) -> Unit,
    onDone: () -> Unit,
    onOpenSource: (Passage) -> Unit,
) {
    val uuid = model.book.uuid
    val context = LocalContext.current
    var question by rememberSaveable(uuid) { mutableStateOf("") }
    var chips by remember(uuid) { mutableStateOf(AskSuggestions.chips(emptyList())) }
    // Whether the last Send arrived before the book had finished laying out.
    var isStillOpening by remember(uuid) { mutableStateOf(false) }
    // Where this question goes. Starts at the reader's default for every new
    // question, so choosing a provider once never quietly sends the next one
    // there too. Only ever more than the phone once a key is registered.
    val choice = remember(uuid) { AskChoice() }
    val resetChoice = { choice.startOver(coordinator.defaultAnswerer) }

    // Keyed on whether the book has finished opening. The sparkle can open
    // this sheet while the book is still laying out, when there is no file to
    // warm up from, and a warm-up keyed on nothing ran once, found nothing,
    // and was never run again.
    LaunchedEffect(uuid, model.epubPackage != null) {
        // A key that would not read at launch counts once it reads.
        coordinator.refreshKeys()
        // Before the availability check: a notification delivered while Ask
        // was on must not be left in the shade after it is turned off.
        coordinator.reopened(uuid)
        // Availability can have changed since it was last read — the model may
        // have finished downloading — and this is the moment the copy has to
        // be right. Read only while Ask is on.
        coordinator.checkAvailability()?.join()
        // The default as it now stands — unless the reader has already picked:
        // a check, or the book finishing opening, landing after their pick
        // must not move the question somewhere they did not choose.
        if (coordinator.job(uuid) == null) choice.offerDefault(coordinator.defaultAnswerer)
        // The index is built and the chips found wherever something can
        // answer. Nothing in this is a request to a provider: only Gemini Nano
        // is ever warmed (`AskCoordinator.prepare`).
        if (!coordinator.canAsk) return@LaunchedEffect
        coordinator.prepare(model)
        chips = coordinator.suggestions(model)
    }

    // The places this question could go: empty for nearly everyone, and then
    // the sheet is exactly what it was — no picker until a key is registered.
    val choices = coordinator.answerChoices
    val answererChoice = if (!coordinator.keys.hasAny) {
        null
    } else {
        val chosen = if (choice.answerer in choices) choice.answerer else choices.firstOrNull() ?: AskAnswerer.DEVICE
        AskAnswererChoice(
            choices = choices,
            chosen = chosen,
            title = { AskDefaults.choiceTitle(it, coordinator.providerModelName(it)) },
            // Gemini Nano chosen while it cannot answer yet says why, rather
            // than the question going somewhere the reader did not pick.
            caption = (if (chosen == AskAnswerer.DEVICE) coordinator.deviceNotice else null) ?: AskDefaults.caption(chosen),
            onChoose = choice::pick,
        )
    }

    val job = coordinator.job(uuid)
    AskSheetContent(
        notice = coordinator.sheetNotice,
        isReady = coordinator.canAsk,
        job = job,
        chips = chips,
        question = question,
        onQuestionChange = { question = it },
        isStillOpening = isStillOpening,
        height = height,
        actions = AskSheetActions(
            // Sends the question, or says why it could not be sent: a book
            // still laying out has no position or file yet, and a question
            // dropped then vanished with no message. The question is kept,
            // because the fix is to send it again a moment later.
            send = send@{ text ->
                val asked = text.trim()
                if (asked.isEmpty()) return@send false
                val answerer = answererChoice?.chosen ?: AskAnswerer.DEVICE
                // Gemini Nano, chosen while it cannot answer yet: the caption
                // already says why, and the question stays in the field.
                if (answererChoice != null && answerer == AskAnswerer.DEVICE && coordinator.deviceNotice != null) {
                    return@send false
                }
                if (coordinator.ask(asked, model, answerer) == null) {
                    isStillOpening = true
                    return@send false
                }
                isStillOpening = false
                question = ""
                true
            },
            cancel = { coordinator.cancel(uuid) },
            askAnother = { coordinator.discard(uuid) },
            // Non-expiring: an answer is the reader's, and a Copy that empties
            // itself after two minutes is a Copy that sometimes does nothing.
            copy = { Clipboard.copy(context, it, lifetime = null) },
            // Asked where it was asked before: a reader's provider again, not the phone.
            tryAgain = { coordinator.ask(it, model, coordinator.job(uuid)?.answerer ?: AskAnswerer.DEVICE) },
            // Only where Gemini Nano can answer, and only when the reader asks.
            answerOnDevice = if (coordinator.isReady) ({ coordinator.ask(it, model, AskAnswerer.DEVICE) }) else null,
            done = onDone,
            sourceTitle = { model.title(it.passage.spineIndex, it.passage.start) },
            openSource = { onOpenSource(it.passage) },
            contentHeight = onContentHeight,
            resetChoice = resetChoice,
        ),
        answererChoice = answererChoice,
        providerModel = job?.providerModelName ?: coordinator.providerModelName(answererChoice?.chosen ?: AskAnswerer.DEVICE),
    )
}

/**
 * Where this question goes: the reader's default until they pick, and their
 * pick after. A default offered late — the availability check, or the book
 * finishing opening — never moves a pick; a new question starts at the
 * default again.
 */
internal class AskChoice(initial: AskAnswerer = AskAnswerer.DEVICE) {
    var answerer: AskAnswerer by mutableStateOf(initial)
        private set
    private var picked = false

    /** The reader's default, unless the reader has picked already. */
    fun offerDefault(default: AskAnswerer) {
        if (!picked) answerer = default
    }

    /** The reader picked. */
    fun pick(place: AskAnswerer) {
        answerer = place
        picked = true
    }

    /** A new question starts at the default again. */
    fun startOver(default: AskAnswerer) {
        answerer = default
        picked = false
    }
}

/**
 * Where the question goes, once the reader has a key of their own: the
 * places it could go, the one chosen, and the sentence that says what that
 * means.
 */
internal class AskAnswererChoice(
    val choices: List<AskAnswerer>,
    val chosen: AskAnswerer,
    val title: (AskAnswerer) -> String,
    val caption: String,
    val onChoose: (AskAnswerer) -> Unit,
)

/** What the sheet's controls do, so the drawing can be shown without a reader or a coordinator behind it. */
internal class AskSheetActions(
    /** @return whether the question went; false keeps it in the field. */
    val send: (String) -> Boolean = { true },
    val cancel: () -> Unit = {},
    val askAnother: () -> Unit = {},
    val copy: (String) -> Unit = {},
    val tryAgain: (String) -> Unit = {},
    /**
     * Asks Gemini Nano a question the reader's provider could not answer —
     * null where Gemini Nano cannot answer either.
     */
    val answerOnDevice: ((String) -> Unit)? = null,
    val done: () -> Unit = {},
    val sourceTitle: (AskSource) -> String? = { null },
    val openSource: (AskSource) -> Unit = {},
    /** The answered state's height, for the sheet to decide whether to grow. */
    val contentHeight: (Dp) -> Unit = {},
    /** Puts the question's destination back to the reader's default, as a new question starts. */
    val resetChoice: () -> Unit = {},
)

/**
 * The sheet's drawing: the header, one of its four states, and the origin
 * pill at its foot.
 *
 * @param notice what to say instead of a question field — Ask off, the model
 *   still downloading, a phone that cannot run it — or null.
 * @param isReady whether a question can be asked now: the origin pill is only
 *   drawn then.
 * @param height the sheet's height, or null to take all the height offered.
 * @param answererChoice where the question goes, once the reader has a key of
 *   their own; null — no picker at all — until then.
 * @param providerModel the model the pill names, for a question going to a
 *   reader's own provider.
 */
@Composable
internal fun AskSheetContent(
    notice: String?,
    isReady: Boolean,
    job: AskJob?,
    chips: List<String>,
    question: String,
    onQuestionChange: (String) -> Unit,
    isStillOpening: Boolean,
    actions: AskSheetActions,
    modifier: Modifier = Modifier,
    height: Dp? = null,
    focusesField: Boolean = true,
    answererChoice: AskAnswererChoice? = null,
    providerModel: String? = null,
) {
    // What the pill at the foot has to say, when it has anything: nothing for
    // a notice or a failure, which have nothing to disclose, and nothing for a
    // withheld answer, which no machine wrote. Not nothing for the composer:
    // the reader deciding whether to type is the one who most needs to know
    // the answer will be worked out here.
    val originState: AskOriginState? = if (!isReady || notice != null) {
        null
    } else {
        when (val state = job?.state) {
            null -> AskOriginState.Unanswered(answererChoice?.chosen ?: AskAnswerer.DEVICE)
            is AskJob.State.Working -> AskOriginState.Unanswered(job.answerer)
            is AskJob.State.Answered ->
                if (state.answer.origin == AskAnswer.Origin.WITHHELD) null else AskOriginState.Answered(state.answer.origin, job.answerer)
            is AskJob.State.Failed -> null
        }
    }

    Column(
        modifier
            .fillMaxWidth()
            .then(if (height != null) Modifier.height(height) else Modifier.fillMaxHeight())
            .background(Palette.paper)
            .padding(start = Metrics.spacing24, end = Metrics.spacing24, top = Metrics.spacing12, bottom = Metrics.spacing24),
    ) {
        Header(onDone = actions.done)
        Spacer(Modifier.height(Metrics.spacing16))
        Column(
            Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState()),
        ) {
            when {
                notice != null -> Unavailable(notice)
                job != null -> when (val state = job.state) {
                    is AskJob.State.Working -> Working(job, actions)
                    // An answer with no prose in it is a failure that got this
                    // far: the engine refuses those now, so this is the last
                    // line of defence.
                    is AskJob.State.Answered ->
                        if (state.answer.text.isEmpty()) {
                            Failed(job, AskFailure.Other(AskFailure.couldNotAnswer), actions)
                        } else {
                            Answered(job, state.answer, actions)
                        }
                    is AskJob.State.Failed -> Failed(job, state.failure, actions)
                }
                else -> Compose(chips, question, onQuestionChange, isStillOpening, actions, focusesField, answererChoice)
            }
        }
        // Pushed to the foot of the sheet, outside the answer's own column:
        // that one is measured to decide the sheet's height, and a pill that
        // grew the measurement would open sheets full height for a caption.
        if (originState != null) {
            Spacer(Modifier.height(Metrics.spacing16))
            AskOriginPill(originState, providerModel = providerModel)
        }
    }
}

// Chrome

@Composable
private fun Header(onDone: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        Text("Ask about this book", style = Typography.headline, color = Palette.ink)
        BetaPill()
        Spacer(Modifier.weight(1f))
        SheetButton("Done", onClick = onDone, color = Palette.tangerine, emphasised = true)
    }
}

/** The sheet's grabber: the iPhone's, a short capsule at the top edge. */
@Composable
internal fun SheetGrabber() {
    Box(Modifier.fillMaxWidth().padding(top = Metrics.spacing8), contentAlignment = Alignment.Center) {
        Box(Modifier.size(width = 36.dp, height = 5.dp).background(Palette.borderStrong, CircleShape))
    }
}

/** A word that acts, in the sheet's ramp: the accent and semibold for the step forward, quiet ink for the rest. */
@Composable
private fun SheetButton(title: String, onClick: () -> Unit, color: Color, emphasised: Boolean = false, modifier: Modifier = Modifier) {
    Text(
        title,
        style = if (emphasised) Typography.callout.copy(fontWeight = FontWeight.SemiBold) else Typography.callout,
        color = color,
        modifier = modifier
            .clip(RoundedCornerShape(Metrics.radiusSmall))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(vertical = Metrics.spacing4),
    )
}

@Composable
private fun AskedQuestion(text: String) {
    Text(text, style = Typography.callout.copy(fontWeight = FontWeight.SemiBold), color = Palette.inkSecondary)
}

@Composable
private fun Stack(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Metrics.spacing16), content = content)
}

// Compose

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Compose(
    chips: List<String>,
    question: String,
    onQuestionChange: (String) -> Unit,
    isStillOpening: Boolean,
    actions: AskSheetActions,
    focusesField: Boolean,
    answererChoice: AskAnswererChoice?,
) {
    val focus = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    val send: (String) -> Unit = { text -> if (actions.send(text)) focusManager.clearFocus() }
    Stack {
        val shape = RoundedCornerShape(Metrics.radiusMedium)
        BasicTextField(
            value = question,
            onValueChange = onQuestionChange,
            textStyle = Typography.body.copy(color = Palette.ink),
            cursorBrush = SolidColor(Palette.tangerine),
            singleLine = true,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { send(question) }),
            modifier = Modifier.fillMaxWidth().focusRequester(focus).testTag("ask.field"),
            decorationBox = { field ->
                Box(
                    Modifier
                        .fillMaxWidth()
                        .background(Palette.surface, shape)
                        .border(1.dp, Palette.border, shape)
                        .padding(Metrics.spacing12),
                ) {
                    if (question.isEmpty()) Text("Ask about the story so far…", style = Typography.body, color = Palette.inkTertiary)
                    field()
                }
            },
        )

        if (answererChoice != null) AnswererPicker(answererChoice)

        // Six, wrapped: the chips are different lengths, and a fixed row
        // leaves the last one half off the screen.
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8),
            verticalArrangement = Arrangement.spacedBy(Metrics.spacing8),
        ) {
            for (chip in chips) {
                Text(
                    chip,
                    style = Typography.footnote,
                    color = Palette.inkSecondary,
                    maxLines = 2,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(Palette.surface, CircleShape)
                        .border(1.dp, Palette.border, CircleShape)
                        .clickable(role = Role.Button) {
                            onQuestionChange(chip)
                            send(chip)
                        }
                        .padding(horizontal = Metrics.spacing12, vertical = Metrics.spacing8),
                )
            }
        }

        // The chips take the same path as the field, so they need the same
        // answer: tapping one before the book is laid out used to do nothing.
        if (isStillOpening) {
            Text(
                "Still opening this book. Try again in a moment.",
                style = Typography.footnote,
                color = Palette.inkTertiary,
                modifier = Modifier.testTag("ask.stillOpening"),
            )
        }
    }
    // Focused on appear: the reader opened this to type. And every new
    // question starts at the reader's default.
    LaunchedEffect(Unit) {
        actions.resetChoice()
        if (focusesField) focus.requestFocus()
    }
}

/**
 * Where this question goes, once the reader has a key of their own: this
 * phone, or their provider. A menu, because the places do not fit a phone's
 * width side by side at the larger text sizes — and never a menu of one: with
 * a single place (a key on a phone without Gemini Nano) only the sentence
 * saying where the question goes is shown.
 */
@Composable
private fun AnswererPicker(choice: AskAnswererChoice) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
        if (choice.choices.size > 1) {
            var open by remember { mutableStateOf(false) }
            Box {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(Metrics.radiusSmall))
                        .clickable(role = Role.Button) { open = true }
                        .padding(vertical = Metrics.spacing4)
                        .testTag("ask.answerer"),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8),
                ) {
                    Text("Answer with", style = Typography.callout, color = Palette.ink)
                    Spacer(Modifier.weight(1f))
                    Text(
                        choice.title(choice.chosen),
                        style = if (Palette.isEInk) Typography.callout.copy(fontWeight = FontWeight.SemiBold) else Typography.callout,
                        color = Palette.tangerine,
                        maxLines = 2,
                    )
                    Icon(
                        painterResource(Symbols.chevronUpChevronDown),
                        contentDescription = null,
                        tint = Palette.tangerine,
                        modifier = Modifier.size(16.dp),
                    )
                }
                PaperMenu(expanded = open, onDismissRequest = { open = false }) {
                    for (place in choice.choices) {
                        DropdownMenuItem(
                            text = {
                                Text(
                                    choice.title(place),
                                    style = if (place == choice.chosen && Palette.isEInk) {
                                        Typography.body.copy(fontWeight = FontWeight.SemiBold)
                                    } else {
                                        Typography.body
                                    },
                                    color = Palette.ink,
                                )
                            },
                            trailingIcon = if (place == choice.chosen) {
                                { Icon(painterResource(Symbols.checkmark), contentDescription = "Selected", tint = Palette.tangerine) }
                            } else {
                                null
                            },
                            onClick = {
                                open = false
                                choice.onChoose(place)
                            },
                            modifier = Modifier.testTag("ask.answerer.${place.rawValue}"),
                        )
                    }
                }
            }
        }
        Text(
            choice.caption,
            style = Typography.footnote,
            color = Palette.inkTertiary,
            modifier = Modifier.testTag("ask.answerer.caption"),
        )
    }
}

// Working

@Composable
private fun Working(job: AskJob, actions: AskSheetActions) {
    Stack {
        AskedQuestion(job.question)
        job.phaseLine?.let { Text(it, style = Typography.footnote, color = Palette.inkTertiary) }
        if (job.partial.isEmpty()) {
            PlaceholderBars()
        } else {
            SelectionContainer { Text(job.partial, style = Typography.body, color = Palette.ink) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing16)) {
            SheetButton("Cancel", onClick = actions.cancel, color = Palette.inkSecondary)
        }
        Text(
            "You can close this; you'll be told when the answer is ready.",
            style = Typography.footnote,
            color = Palette.inkTertiary,
        )
    }
}

// Answer

@Composable
private fun Answered(job: AskJob, answer: AskAnswer, actions: AskSheetActions) {
    val density = LocalDensity.current
    // Measured here rather than on the whole sheet: this is the state that can
    // outgrow half a screen, and the others must not drag it open.
    Stack(Modifier.onSizeChanged { with(density) { actions.contentHeight(it.height.toDp()) } }) {
        AskedQuestion(job.question)
        SelectionContainer {
            Text(answer.text, style = Typography.body, color = Palette.ink, modifier = Modifier.testTag("ask.answer"))
        }
        // Inside this column on purpose: it is part of the answer, so the
        // height an opened excerpt adds is height the sheet should grow to fit.
        AskSourcesRow(sources = answer.sources, title = actions.sourceTitle, onOpen = actions.openSource)
        // Kept on the boundary rather than written here, so no two screens can
        // come to word the same claim differently.
        Text(job.boundary.footer, style = Typography.footnote, color = Palette.inkTertiary)
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing16)) {
            SheetButton("Ask another", onClick = actions.askAnother, color = Palette.tangerine, emphasised = true)
            SheetButton("Copy", onClick = { actions.copy(answer.text) }, color = Palette.inkSecondary)
        }
    }
}

// Failure and unavailability

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Failed(job: AskJob, failure: AskFailure, actions: AskSheetActions) {
    Stack {
        AskedQuestion(job.question)
        Text(failure.message(AskDevice.noun, job.answerer), style = Typography.body, color = Palette.ink)
        // The reader's provider refused, ran out or could not be reached:
        // Gemini Nano may well answer, and asking it is the reader's call —
        // where it can answer at all. Never asked behind their back.
        val answerOnDevice = actions.answerOnDevice?.takeIf { job.answerer != AskAnswerer.DEVICE && failure.offersDeviceInstead }
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing16),
            verticalArrangement = Arrangement.spacedBy(Metrics.spacing8),
        ) {
            SheetButton("Try again", onClick = { actions.tryAgain(job.question) }, color = Palette.tangerine, emphasised = true)
            if (answerOnDevice != null) {
                SheetButton(
                    "Answer on this ${AskDevice.noun}",
                    onClick = { answerOnDevice(job.question) },
                    color = Palette.tangerine,
                    modifier = Modifier.testTag("ask.answerOnDevice"),
                )
            }
            SheetButton("Done", onClick = actions.done, color = Palette.inkSecondary)
        }
    }
}

/** One sentence, and never a switch: a switch that can do nothing is worse than an explanation. */
@Composable
private fun Unavailable(sentence: String) {
    Text(sentence, style = Typography.body, color = Palette.inkSecondary)
}

// MARK: -

/**
 * Three bars where the answer will be, sweeping.
 *
 * A shimmer rather than a spinner because the wait is five to thirty seconds
 * and the shape of what is coming is known: a spinner says "something is
 * happening", these say "prose is coming, here". They are replaced the moment
 * the first words stream in.
 */
@Composable
private fun PlaceholderBars() {
    if (Palette.isEInk) {
        WaitingIndicator(color = Palette.ink, strokeWidth = 2.dp, size = 16.dp, modifier = Modifier.semantics { contentDescription = "Working out the answer" })
        return
    }
    val moves = LocalAskMotion.current
    val transition = if (moves) rememberInfiniteTransition(label = "placeholder bars") else null
    Column(
        Modifier.fillMaxWidth().semantics { contentDescription = "Working out the answer" },
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing8),
    ) {
        for ((index, fraction) in listOf(1f, 0.92f, 0.6f).withIndex()) {
            // Staggered, so the three read as one sweep down the paragraph
            // rather than three things blinking together.
            val lit = transition?.animateFloat(
                initialValue = 0f,
                targetValue = 1f,
                animationSpec = infiniteRepeatable(
                    tween(900, easing = EaseInOut),
                    RepeatMode.Reverse,
                    initialStartOffset = StartOffset(index * 120),
                ),
                label = "bar $index",
            )?.value ?: 0f
            Box(
                Modifier
                    .fillMaxWidth(fraction)
                    .height(12.dp)
                    .background(lerp(Palette.border, Palette.borderStrong, lit), CircleShape),
            )
        }
    }
}
