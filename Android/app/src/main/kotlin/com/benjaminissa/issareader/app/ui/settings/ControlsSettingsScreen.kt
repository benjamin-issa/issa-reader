package com.benjaminissa.issareader.app.ui.settings

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.playback.CommandMap
import com.benjaminissa.issareader.playback.ControlSurface
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.playback.PlaybackControl
import com.benjaminissa.issareader.ui.ButtonRow
import com.benjaminissa.issareader.ui.PickerRow
import com.benjaminissa.issareader.ui.StepperRow
import com.benjaminissa.issareader.ui.paperSection

/**
 * Assign an action to each control, per surface: `ControlsSettingsView.swift`.
 *
 * The feature that makes the steering-wheel buttons genuinely useful: what
 * `»` should do differs between sitting on the sofa and driving.
 */
@Composable
internal fun ControlsSettingsScreen(
    settings: PlaybackSettings,
    onBack: (() -> Unit)?,
    initialSurface: ControlSurface = ControlSurface.PHONE,
    largeTitle: Boolean = true,
) {
    var surface by rememberSaveable { mutableStateOf(initialSurface) }
    val map = settings.commandMap

    // Worth saying, because it is the one binding with a visible side effect
    // elsewhere: the system's media controls show the skip buttons only while
    // nothing claims the track buttons. Nothing to say about a car, which has
    // no lock screen — so that surface gets no note at all.
    val wheelNote: String? = when {
        surface == ControlSurface.CAR -> null
        map.usesTrackCommands(surface) -> "The lock screen shows next and previous track while the wheel is assigned."
        else -> "Leave the wheel unassigned and the lock screen shows the skip buttons instead."
    }

    SettingsPage(title = "Controls", onBack = onBack, largeTitle = largeTitle) {
        paperSection(
            key = "surface",
            footer = "Assign an action to each button. Bindings are per surface, so the wheel can mean something different in the car.",
        ) {
            row {
                SegmentedRow(
                    options = ControlSurface.entries,
                    selection = surface,
                    label = { it.title },
                    onSelect = { surface = it },
                )
            }
        }

        paperSection(key = "buttons", header = "Buttons", footer = wheelNote) {
            for (control in ControlsSettings.controls(surface)) {
                row {
                    PickerRow(
                        control.title,
                        selection = map.action(control, surface),
                        options = ControlsSettings.actions(map, control, surface),
                        label = { it.title },
                        onSelect = { settings.commandMap = settings.commandMap.withBinding(it, control, surface) },
                    )
                }
            }
        }

        // One setting, three places: the note names the jump buttons beside
        // the chapter name on the reading page, which move by this too.
        paperSection(
            key = "skip",
            header = "Skip amount",
            footer = "Used by the skip buttons wherever narration is playing — the player, the lock screen, Android Auto — and by the jump buttons next to the chapter name on the reading page.",
        ) {
            // The range is `CommandMap`'s own, not a pair of numbers typed
            // here: the decoder clamps a stored interval to it, and a stepper
            // offering a value the decoder would refuse is a setting that
            // quietly moves after a relaunch.
            row {
                StepperRow(
                    "Forward",
                    value = map.skipForwardInterval,
                    range = CommandMap.intervalRange,
                    onValueChange = { settings.commandMap = settings.commandMap.copy(skipForwardInterval = it) },
                    step = 5.0,
                    format = { "${it.toInt()}s" },
                )
            }
            row {
                StepperRow(
                    "Back",
                    value = map.skipBackwardInterval,
                    range = CommandMap.intervalRange,
                    onValueChange = { settings.commandMap = settings.commandMap.copy(skipBackwardInterval = it) },
                    step = 5.0,
                    format = { "${it.toInt()}s" },
                )
            }
        }

        paperSection(key = "reset") {
            row { ButtonRow("Reset ${surface.title} to defaults", onClick = { settings.resetBindings(surface) }) }
        }
    }
}

/** What the Controls screen offers, without the screen. */
internal object ControlsSettings {
    /**
     * Only the controls that surface actually exposes, and that this app can
     * actually make fire.
     *
     * The wheel belongs on the phone's list too, even though the phone has no
     * wheel: next and previous track is where headphones' double- and
     * triple-press arrive, and where a Bluetooth head unit's buttons arrive.
     *
     * The double-tap and hold controls are absent everywhere: nothing fires
     * them (see [PlaybackControl]), so rebinding one would silently do
     * nothing. Headphones list only the wheel for the same reason: a single
     * press is play/pause by the system's contract and never consults a
     * binding.
     */
    fun controls(surface: ControlSurface): List<PlaybackControl> = when (surface) {
        ControlSurface.PHONE, ControlSurface.CAR ->
            listOf(PlaybackControl.TAP_FORWARD, PlaybackControl.TAP_BACKWARD, PlaybackControl.WHEEL_NEXT, PlaybackControl.WHEEL_PREVIOUS)
        ControlSurface.HEADPHONES -> listOf(PlaybackControl.WHEEL_NEXT, PlaybackControl.WHEEL_PREVIOUS)
    }

    /**
     * What the picker offers: the assignable actions, plus whatever this
     * control is already bound to. The addition matters for a reader carrying
     * a binding no longer on offer — `sleepTimer` was pickable back when
     * nothing performed it — whose row would otherwise draw with no selection.
     */
    fun actions(map: CommandMap, control: PlaybackControl, surface: ControlSurface): List<PlaybackAction> {
        val current = map.action(control, surface)
        val options = PlaybackAction.assignable
        return if (current in options) options else options + current
    }
}
