package com.benjaminissa.issareader.ui

import android.content.Context

internal fun bundledFontNames(context: Context): List<String> = context.assets.list("Fonts")?.sorted().orEmpty()
