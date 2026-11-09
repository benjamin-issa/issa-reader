package com.benjaminissa.issareader.app

import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionContext
import androidx.compose.ui.MotionDurationScale
import androidx.compose.ui.platform.createLifecycleAwareWindowRecomposer

/**
 * The duration scale "Remove animations" sets. A composition that carries it
 * has no animation in it: Compose's own, Material's and the app's all read
 * the scale from the context they run in, and at zero each goes straight to
 * its end, which is what a panel that ghosts through every in-between frame
 * needs. Dialogs, menus and sheets compose under their parent and inherit it.
 */
internal object NoMotion : MotionDurationScale {
    override val scaleFactor: Float get() = 0f
}

/**
 * The parent for E-Ink mode's composition: the recomposer a window gets by
 * default, which stops with the activity's lifecycle, with [NoMotion] in place
 * of the system's scale.
 */
internal fun ComponentActivity.motionlessComposition(): CompositionContext =
    window.decorView.createLifecycleAwareWindowRecomposer(NoMotion, lifecycle)
