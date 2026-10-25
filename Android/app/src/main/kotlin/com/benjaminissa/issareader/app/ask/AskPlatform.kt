package com.benjaminissa.issareader.app.ask

import android.content.Context
import com.benjaminissa.issareader.ask.AnswerModel
import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.android.GeminiNanoAnswerModel
import com.benjaminissa.issareader.ask.android.GeminiNanoAvailability
import com.benjaminissa.issareader.ask.android.MlKitStartup
import com.benjaminissa.issareader.ask.android.ModelDownload
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow

/**
 * Everything the app asks of Gemini Nano, behind one seam: whether this phone
 * can answer, getting the model onto it, and the model itself.
 *
 * A seam for one reason. ML Kit reports to Google from its first call, and the
 * reader decided that with Ask off nothing goes to Google — so with Ask off
 * none of these may be called, not at launch, not when Settings opens, not
 * when a book opens. [AskCoordinator] is the only caller, and it calls
 * nothing here until the switch is on; a test hands it a counting stand-in and
 * asserts exactly that.
 *
 * Constructing an implementation must cost nothing and touch nothing: the
 * app builds [GeminiNanoPlatform] at launch whatever the switch says.
 */
interface AskPlatform {
    /** ML Kit's feature status, read fresh. */
    suspend fun availability(): AskAvailability

    /** The model's download, reporting as it goes; ends with the outcome. */
    fun download(): Flow<ModelDownload>

    /** The answer model the engines are built on. Called once, the first time one is needed. */
    fun makeModel(): AnswerModel
}

/**
 * Gemini Nano through ML Kit: [GeminiNanoAvailability] and
 * [GeminiNanoAnswerModel], with ML Kit started by hand immediately before
 * the first of them ([MlKitStartup]) — the app's manifest removes ML Kit's own
 * start-up provider, which would otherwise have run at process start.
 */
class GeminiNanoPlatform(context: Context) : AskPlatform {
    private val context: Context = context.applicationContext ?: context

    private fun start() = MlKitStartup.ensureStarted(context)

    override suspend fun availability(): AskAvailability {
        start()
        return GeminiNanoAvailability.current()
    }

    override fun download(): Flow<ModelDownload> = flow {
        start()
        emitAll(GeminiNanoAvailability.download())
    }

    override fun makeModel(): AnswerModel {
        start()
        return GeminiNanoAnswerModel()
    }
}
