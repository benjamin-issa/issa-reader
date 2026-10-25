package com.benjaminissa.issareader.app.ui.local

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.benjaminissa.issareader.ui.Palette

/**
 * PLACEHOLDER — the local-books port replaces this file with
 * `LocalBooksScreen.swift`. [standalone] is the signed-out root (Swift's
 * `.standalone` placement); otherwise it is pushed from Settings.
 * [onConnectServer] takes a signed-out reader back to the sign-in screen.
 */
@Composable
fun LocalBooksScreen(standalone: Boolean, onConnectServer: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Palette.paper))
}
