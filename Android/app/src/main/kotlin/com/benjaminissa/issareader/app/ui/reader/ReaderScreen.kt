package com.benjaminissa.issareader.app.ui.reader

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.benjaminissa.issareader.ui.Palette

/**
 * PLACEHOLDER — the reader port replaces this file with `ReaderView.swift`'s
 * screen. The shell presents it full screen over the tabs and pops it on
 * [onClose].
 */
@Composable
fun ReaderScreen(bookUuid: String, local: Boolean, onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    Box(Modifier.fillMaxSize().background(Palette.paper))
}
