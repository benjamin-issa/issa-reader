package com.benjaminissa.issareader.ask.android

import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.transformWhile
import kotlin.coroutines.cancellation.CancellationException

/**
 * Whether this device can answer a question, and getting it there: ML Kit's
 * feature status read as [AskAvailability], and the model's download.
 */
object GeminiNanoAvailability {
    /**
     * Read fresh every time rather than cached: the model may have finished
     * downloading, or the system may have updated its AI service, since the
     * app launched — exactly the moment the copy on screen has to change.
     */
    suspend fun current(): AskAvailability = current(MlKitPromptBackend.shared)

    internal suspend fun current(backend: PromptBackend): AskAvailability = try {
        availability(backend.status())
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Exception) {
        availability(error)
    }

    /** ML Kit's `FeatureStatus`. */
    internal fun availability(status: Int): AskAvailability = when (status) {
        FeatureStatus.AVAILABLE -> AskAvailability.AVAILABLE
        FeatureStatus.DOWNLOADING -> AskAvailability.MODEL_DOWNLOADING
        FeatureStatus.DOWNLOADABLE -> AskAvailability.MODEL_DOWNLOADABLE
        // Including whatever status a later ML Kit adds: an unknown state the
        // reader cannot act on reads best as "not on this device".
        else -> AskAvailability.UNSUPPORTED_DEVICE
    }

    /**
     * Asking for the status can itself fail: on a device whose AI service is
     * too old, that is how ML Kit says so.
     */
    internal fun availability(error: Throwable): AskAvailability {
        val code = (error as? GenAiException)?.errorCode ?: (error.cause as? GenAiException)?.errorCode
        return when (code) {
            GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE,
            GenAiException.ErrorCode.AICORE_INCOMPATIBLE,
            -> AskAvailability.NEEDS_SYSTEM_UPDATE
            else -> {
                IssaLog.warning("ask availability unreadable", mapOf("code" to (code?.toString() ?: error.javaClass.simpleName)))
                AskAvailability.UNSUPPORTED_DEVICE
            }
        }
    }

    /**
     * Downloads the model, reporting as it goes. Only worth calling when
     * [current] says [AskAvailability.MODEL_DOWNLOADABLE] — nothing downloads
     * it on its own — and safe to call again after a failure.
     *
     * The flow ends after [ModelDownload.Completed] or [ModelDownload.Failed];
     * it does not throw for a failed download.
     */
    fun download(): Flow<ModelDownload> = download(MlKitPromptBackend.shared)

    internal fun download(backend: PromptBackend): Flow<ModelDownload> = flow {
        // Per collection: the start says how much there is, and each progress
        // event is measured against it.
        var total: Long? = null
        val events = backend.download()
            .catch { error ->
                if (error is CancellationException) throw error
                emit(DownloadStatus.DownloadFailed(error as? GenAiException ?: GenAiException(error, GenAiException.ErrorCode.UNKNOWN)))
            }
            .transformWhile { status ->
                val event = when (status) {
                    is DownloadStatus.DownloadStarted -> ModelDownload.Started(status.bytesToDownload).also { total = status.bytesToDownload }
                    is DownloadStatus.DownloadProgress -> ModelDownload.Progress(status.totalBytesDownloaded, total)
                    is DownloadStatus.DownloadCompleted -> ModelDownload.Completed
                    is DownloadStatus.DownloadFailed -> ModelDownload.Failed(GeminiNanoAnswerModel.failure(status.e))
                }
                emit(event)
                // Ends with the outcome, whether or not ML Kit's flow does.
                event !is ModelDownload.Completed && event !is ModelDownload.Failed
            }
        emitAll(events)
    }
}

/** The model's download, as the settings screen shows it. */
sealed interface ModelDownload {
    /** The download has begun, and how much there is. */
    data class Started(val bytesToDownload: Long) : ModelDownload

    /** How far it has got; [totalBytes] is null when the start did not say. */
    data class Progress(val bytesDownloaded: Long, val totalBytes: Long?) : ModelDownload {
        /** 0 to 1, or null when there is no total to measure against. */
        val fraction: Double? get() = totalBytes?.takeIf { it > 0 }?.let { (bytesDownloaded.toDouble() / it).coerceIn(0.0, 1.0) }
    }

    data object Completed : ModelDownload

    /** It stopped, with what to tell the reader. */
    data class Failed(val failure: AskFailure) : ModelDownload
}
