package com.benjaminissa.issareader.app.ask

import android.content.Context
import android.content.pm.PackageManager
import com.benjaminissa.issareader.ask.AnswerModel
import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.android.GeminiNanoAnswerModel
import com.benjaminissa.issareader.ask.android.GeminiNanoAvailability
import com.benjaminissa.issareader.ask.android.MlKitStartup
import com.benjaminissa.issareader.ask.android.ModelDownload
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
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
    /**
     * Whether this phone has the system service the model runs in at all.
     * Answered without calling ML Kit, so it may be read with Ask off: a phone
     * without it gets the switch disabled up front.
     */
    val hasSystemService: Boolean get() = true

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

    /** A package-manager lookup, never ML Kit: the app's manifest `<queries>` makes it visible on Android 11. */
    override val hasSystemService: Boolean
        get() = try {
            context.packageManager.getPackageInfo(AICORE_PACKAGE, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        } catch (error: Exception) {
            IssaLog.warning("ask system service unreadable", mapOf("error" to error.javaClass.simpleName))
            false
        }

    private fun start() = MlKitStartup.ensureStarted(context)

    /**
     * Total: ML Kit on a phone without Gemini Nano can throw anything, `Error`s
     * (a missing class) included, and a throw here once took the process down on
     * every launch. Anything but a cancellation reads as "this phone can't".
     */
    override suspend fun availability(): AskAvailability = try {
        start()
        GeminiNanoAvailability.current()
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        IssaLog.error("ask availability threw", mapOf("error" to error.javaClass.name))
        AskAvailability.UNSUPPORTED_DEVICE
    }

    override fun download(): Flow<ModelDownload> = flow {
        start()
        emitAll(GeminiNanoAvailability.download())
    }.catch { error ->
        if (error is CancellationException) throw error
        IssaLog.error("ask download threw", mapOf("error" to error.javaClass.name))
        emit(ModelDownload.Failed(AskFailure.Other(AskCopy.unsupported())))
    }

    /** May throw; [AskCoordinator] is the caller and degrades to "Ask unavailable" when it does. */
    override fun makeModel(): AnswerModel {
        start()
        return GeminiNanoAnswerModel()
    }

    private companion object {
        const val AICORE_PACKAGE = "com.google.android.aicore"
    }
}
