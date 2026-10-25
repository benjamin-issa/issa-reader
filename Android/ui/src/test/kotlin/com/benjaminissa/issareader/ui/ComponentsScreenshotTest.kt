package com.benjaminissa.issareader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberTopAppBarState
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** The grouped list and its rows, laid out as the iPhone's Settings screen is, for comparing by eye. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class ComponentsScreenshotTest {
    @OptIn(ExperimentalMaterial3Api::class)
    @Test
    fun settingsShapedList() {
        captureRoboImage("build/specimen/settings.png") {
            IssaTheme(darkTheme = false) {
                val behavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior(rememberTopAppBarState())
                Box(Modifier.size(402.dp, 874.dp).background(Palette.paper)) {
                    Scaffold(
                        modifier = Modifier.fillMaxSize().nestedScroll(behavior.nestedScrollConnection),
                        containerColor = Palette.paper,
                        topBar = { LargeTitleBar("Settings", behavior) },
                    ) { padding ->
                        PaperList(Modifier.fillMaxSize(), contentPadding = padding) {
                            paperSection(header = "Account") {
                                row { LabeledRow("Signed in as", "sweep") }
                                row { LabeledRow("Server", "http://issa-fixture.test") }
                            }
                            paperSection(header = "Library") {
                                row { LabeledRow("Books", "6") }
                                row { LabeledRow("With narration", "2") }
                            }
                            paperSection(
                                header = "Playback & reading",
                                footer = "The player, the lock screen and Android Auto all show the chapter you are in.",
                            ) {
                                row { PickerRow("Progress bar", "Current chapter", listOf("Current chapter", "Whole book"), { it }, {}) }
                                row(dividerStart = 54.dp) { NavigationRow("Controls & remapping", {}, icon = Symbols.sliderHorizontal3) }
                                row(dividerStart = 54.dp) { NavigationRow("Reading & highlights", {}, icon = Symbols.textformat) }
                                row { NavigationRow("Downloads & storage", {}, icon = Symbols.arrowDownCircle) }
                            }
                            paperSection(header = "Ask AI about this book", headerContent = { BetaPill() }) {
                                row { ToggleRow("Ask about your book", false, {}) }
                            }
                            item {
                                Column {
                                    PalettePlaceholder(Symbols.bookmark, "Nothing in progress", "Books you start reading appear here.", actionTitle = "Go to Library", action = {})
                                    ProgressBar(0.51, Modifier.size(200.dp, 3.dp))
                                    StepperRow("Text size", 18.0, 12.0..32.0, {}, format = { "${it.toInt()}pt" })
                                    PrimaryButton("Continue in browser", {}, trailingIcon = Symbols.arrowUpRight)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
