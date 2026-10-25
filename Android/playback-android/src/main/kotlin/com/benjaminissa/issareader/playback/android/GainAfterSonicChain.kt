package com.benjaminissa.issareader.playback.android

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink

/**
 * The sink's processor chain with the gain stage appended *after* Sonic.
 *
 * Media3's default chain ends in Sonic, the time-stretcher that changes speed
 * with the pitch preserved. Anything passed to the sink's builder as an extra
 * processor goes in front of it, where the gain would be re-scaled by the
 * stretch; iOS creates its tap post-effects for the same reason. So the default
 * chain is kept whole — silence skipping, Sonic, and Sonic's say over the
 * playback parameters and the media duration — and the gain is the last thing
 * the samples pass through on their way to the device.
 */
@OptIn(UnstableApi::class)
class GainAfterSonicChain(private val gain: GainKneeAudioProcessor) : DefaultAudioSink.AudioProcessorChain {
    private val base = DefaultAudioSink.DefaultAudioProcessorChain()
    private val processors: Array<AudioProcessor> = base.audioProcessors + gain

    override fun getAudioProcessors(): Array<AudioProcessor> = processors

    override fun applyPlaybackParameters(playbackParameters: PlaybackParameters): PlaybackParameters =
        base.applyPlaybackParameters(playbackParameters)

    override fun applySkipSilenceEnabled(skipSilenceEnabled: Boolean): Boolean =
        base.applySkipSilenceEnabled(skipSilenceEnabled)

    override fun getMediaDuration(playoutDuration: Long): Long = base.getMediaDuration(playoutDuration)

    override fun getSkippedOutputFrameCount(): Long = base.skippedOutputFrameCount
}

/**
 * The renderers ExoPlayer is built with: the defaults, over a sink whose chain
 * ends in the gain stage.
 *
 * 16-bit output and Sonic for speed, always. Float output would hand the gain
 * stage a format it passes through untouched, and letting the platform's
 * `AudioTrack` apply the speed would put the stretch *after* the gain — the
 * order iOS's post-effects tap exists to avoid.
 */
@OptIn(UnstableApi::class)
class GainRenderersFactory(
    context: Context,
    private val gain: GainKneeAudioProcessor,
) : DefaultRenderersFactory(context) {
    override fun buildAudioSink(
        context: Context,
        enableFloatOutput: Boolean,
        enableAudioTrackPlaybackParams: Boolean,
    ): AudioSink = DefaultAudioSink.Builder(context)
        .setAudioProcessorChain(GainAfterSonicChain(gain))
        .setEnableFloatOutput(false)
        .setEnableAudioTrackPlaybackParams(false)
        .build()
}
