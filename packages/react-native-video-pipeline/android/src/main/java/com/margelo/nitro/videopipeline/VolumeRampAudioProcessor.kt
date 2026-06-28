///
/// VolumeRampAudioProcessor.kt
///
/// Per-clip linear volume envelope for the Android crossfade audio (#43). Ramps
/// the gain 0→1 over the first `headSec` and 1→0 over the last `tailSec` of a
/// clip's (trimmed) PCM stream, so that two clips overlapping in time on the two
/// ping-pong sequences sum to a constant-ish crossfade instead of a doubled
/// volume bump. Mirrors the iOS `AVMutableAudioMix` volume ramps that
/// `composeCrossfadeSources:` applies over each overlap window.
///
/// PCM 16-bit only — the Media3 Transformer decodes audio to PCM before
/// processors run; any other input encoding throws and deactivates the effect.
///

@file:OptIn(UnstableApi::class)

package com.margelo.nitro.videopipeline

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer

internal class VolumeRampAudioProcessor(
  private val totalSec: Double,
  private val headSec: Double,
  private val tailSec: Double,
) : BaseAudioProcessor() {

  private var sampleRate = 0
  private var channelCount = 0
  /// Frames (samples-per-channel) consumed so far, used to place the envelope.
  private var framePos = 0L

  override fun onConfigure(
    inputAudioFormat: AudioProcessor.AudioFormat,
  ): AudioProcessor.AudioFormat {
    if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
      throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
    }
    sampleRate = inputAudioFormat.sampleRate
    channelCount = inputAudioFormat.channelCount
    // Same format out as in — only the sample amplitudes change.
    return inputAudioFormat
  }

  override fun queueInput(inputBuffer: ByteBuffer) {
    val limit = inputBuffer.limit()
    val size = limit - inputBuffer.position()
    if (size <= 0) return
    // Preserve the input buffer's byte order on the output (PCM 16-bit).
    val out = replaceOutputBuffer(size).order(inputBuffer.order())
    while (inputBuffer.position() < limit) {
      val gain = gainAt(framePos)
      for (ch in 0 until channelCount) {
        val sample = inputBuffer.short
        val scaled = (sample * gain).toInt().coerceIn(-32768, 32767).toShort()
        out.putShort(scaled)
      }
      framePos++
    }
    out.flip()
  }

  /// Linear envelope: 0→1 over [0, headSec], flat 1 in the middle, 1→0 over
  /// [totalSec − tailSec, totalSec]. The min of the two ramps handles a clip
  /// short enough that the head and tail windows overlap.
  private fun gainAt(frame: Long): Float {
    if (sampleRate <= 0) return 1f
    val t = frame.toDouble() / sampleRate
    var g = 1.0
    if (headSec > 1e-6 && t < headSec) g = minOf(g, t / headSec)
    if (tailSec > 1e-6 && t > totalSec - tailSec) g = minOf(g, (totalSec - t) / tailSec)
    return g.coerceIn(0.0, 1.0).toFloat()
  }

  override fun onFlush() {
    framePos = 0
  }

  override fun onReset() {
    framePos = 0
    sampleRate = 0
    channelCount = 0
  }
}
