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
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.ask.AskCoordinator
import com.benjaminissa.issareader.app.ask.AskDevice
import com.benjaminissa.issareader.app.ask.AskJob
import com.benjaminissa.issareader.app.model.Clipboard
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.ask.AskAnswer
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ask.AskSource
import com.benjaminissa.issareader.ask.AskSuggestions
import com.benjaminissa.issareader.ask.Passage
import com.benjaminissa.issareader.ui.BetaPill
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Typography
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

    ModalBottomSheet(
        onDismissRequest = ::close,
        sheetState = sheetState,
        containerColor = Palette.paper,
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

    // Keyed on whether the book has finished opening. The sparkle can open
    // this sheet while the book is still laying out, when there is no file to
    // warm up from, and a warm-up keyed on nothing ran once, found nothing,
    // and was never run again.
    LaunchedEffect(uuid, model.epubPackage != null) {
        // Before the availability check: a notification delivered while Ask
        // was on must not be left in the shade after it is turned off.
        coordinator.reopened(uuid)
        // Availability can have changed since it was last read — the model may
        // have finished downloading — and this is the moment the copy has to
        // be right. Read only while Ask is on.
        coordinator.checkAvailability()?.join()
        if (!coordinator.isReady) return@LaunchedEffect
        coordinator.prepare(model)
        chips = coordinator.suggestions(model)
    }

    AskSheetContent(
        notice = coordinator.sheetNotice,
        isReady = coordinator.isReady,
        job = coordinator.job(uuid),
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
                if (coordinator.ask(asked, model) == null) {
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
            tryAgain = { coordinator.ask(it, model) },
            done = onDone,
            sourceTitle = { model.title(it.passage.spineIndex, it.passage.start) },
            openSource = { onOpenSource(it.passage) },
            contentHeight = onContentHeight,
        ),
    )
}

/** What the sheet's controls do, so the drawing can be shown without a reader or a coordinator behind it. */
internal class AskSheetActions(
    /** @return whether the question went; false keeps it in the field. */
    val send: (String) -> Boolean = { true },
    val cancel: () -> Unit = {},
    val askAnother: () -> Unit = {},
    val copy: (String) -> Unit = {},
    val tryAgain: (String) -> Unit = {},
    val done: () -> Unit = {},
    val sourceTitle: (AskSource) -> String? = { null },
    val openSource: (AskSource) -> Unit = {},
    /** The answered state's height, for the sheet to decide whether to grow. */
    val contentHeight: (Dp) -> Unit = {},
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
            null, is AskJob.State.Working -> AskOriginState.Unanswered
            is AskJob.State.Answered ->
                if (state.answer.origin == AskAnswer.Origin.WITHHELD) null else AskOriginState.Answered(state.answer.origin)
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
                else -> Compose(chips, question, onQuestionChange, isStillOpening, actions, focusesField)
            }
        }
        // Pushed to the foot of the sheet, outside the answer's own column:
        // that one is measured to decide the sheet's height, and a pill that
        // grew the measurement would open sheets full height for a caption.
        if (originState != null) {
            Spacer(Modifier.height(Metrics.spacing16))
            AskOriginPill(originState)
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
    // Focused on appear: the reader opened this to type.
    if (focusesField) LaunchedEffect(Unit) { focus.requestFocus() }
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

@Composable
private fun Failed(job: AskJob, failure: AskFailure, actions: AskSheetActions) {
    Stack {
        AskedQuestion(job.question)
        Text(failure.message(AskDevice.noun), style = Typography.body, color = Palette.ink)
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing16)) {
            SheetButton("Try again", onClick = { actions.tryAgain(job.question) }, color = Palette.tangerine, emphasised = true)
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
