package com.benjaminissa.issareader.ask.android

import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.AskFailure
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ML Kit's feature status, read as the settings screen's states. Distinct
 * states because only some are the reader's to fix: a model to download is a
 * button, one downloading is a wait, an old system is a trip to updates.
 */
class GeminiNanoAvailabilityTest {
    @Test
    fun `each feature status is its own state`() = runBlocking {
        val backend = FakePromptBackend()
        for ((status, expected) in listOf(
            FeatureStatus.AVAILABLE to AskAvailability.AVAILABLE,
            FeatureStatus.DOWNLOADING to AskAvailability.MODEL_DOWNLOADING,
            FeatureStatus.DOWNLOADABLE to AskAvailability.MODEL_DOWNLOADABLE,
            FeatureStatus.UNAVAILABLE to AskAvailability.UNSUPPORTED_DEVICE,
            // A status a later ML Kit adds reads as "not on this device".
            42 to AskAvailability.UNSUPPORTED_DEVICE,
        )) {
            backend.statusCode = status
            assertEquals("status $status", expected, GeminiNanoAvailability.current(backend))
        }
        // Only one of them can be asked a question now.
        backend.statusCode = FeatureStatus.AVAILABLE
        assertTrue(GeminiNanoAvailability.current(backend).isReady)
        backend.statusCode = FeatureStatus.DOWNLOADABLE
        assertFalse(GeminiNanoAvailability.current(backend).isReady)
    }

    @Test
    fun `a system too old for the model says so, and anything else is not on this device`() = runBlocking {
        val backend = FakePromptBackend()
        for ((error, expected) in listOf(
            genAi(GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE) to AskAvailability.NEEDS_SYSTEM_UPDATE,
            genAi(GenAiException.ErrorCode.AICORE_INCOMPATIBLE) to AskAvailability.NEEDS_SYSTEM_UPDATE,
            genAi(GenAiException.ErrorCode.NOT_SUPPORTED) to AskAvailability.UNSUPPORTED_DEVICE,
            IllegalStateException("no service") to AskAvailability.UNSUPPORTED_DEVICE,
        )) {
            backend.statusError = error
            assertEquals("$error", expected, GeminiNanoAvailability.current(backend))
        }
    }

    /** Android never produces Apple's two states; they are kept so the settings copy has one list. */
    @Test
    fun `nothing reads as Apple Intelligence or Apple TV`() = runBlocking {
        val backend = FakePromptBackend()
        val seen = HashSet<AskAvailability>()
        for (status in -1..5) {
            backend.statusCode = status
            seen.add(GeminiNanoAvailability.current(backend))
        }
        assertFalse(AskAvailability.APPLE_INTELLIGENCE_OFF in seen)
        assertFalse(AskAvailability.UNSUPPORTED_ON_THIS_PLATFORM in seen)
    }

    @Test
    fun `a download reports its size, its progress against it, and its end`() = runBlocking {
        val backend = FakePromptBackend(
            downloads = listOf(
                DownloadStatus.DownloadStarted(1_000),
                DownloadStatus.DownloadProgress(250),
                DownloadStatus.DownloadProgress(1_000),
                DownloadStatus.DownloadCompleted,
                // Anything after the end is not the reader's concern.
                DownloadStatus.DownloadProgress(2_000),
            ),
        )
        val events = GeminiNanoAvailability.download(backend).toList()
        assertEquals(
            listOf(
                ModelDownload.Started(1_000),
                ModelDownload.Progress(250, 1_000),
                ModelDownload.Progress(1_000, 1_000),
                ModelDownload.Completed,
            ),
            events,
        )
        assertEquals(0.25, (events[1] as ModelDownload.Progress).fraction!!, 0.0)
        assertNull(ModelDownload.Progress(10, null).fraction)
    }

    @Test
    fun `a failed download ends the flow with what to tell the reader, rather than throwing`() = runBlocking {
        val full = FakePromptBackend(
            downloads = listOf(
                DownloadStatus.DownloadStarted(1_000),
                DownloadStatus.DownloadFailed(genAi(GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE)),
            ),
        )
        assertEquals(
            listOf(ModelDownload.Started(1_000), ModelDownload.Failed(AskFailure.Other(GeminiNanoAnswerModel.notEnoughSpace))),
            GeminiNanoAvailability.download(full).toList(),
        )

        // The flow itself failing is the same outcome.
        val broken = FakePromptBackend(downloadError = genAi(GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE))
        assertEquals(
            listOf(ModelDownload.Failed(AskFailure.NeedsSystemUpdate)),
            GeminiNanoAvailability.download(broken).toList(),
        )
    }
}
