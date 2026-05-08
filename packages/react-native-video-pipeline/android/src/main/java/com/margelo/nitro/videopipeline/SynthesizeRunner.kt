///
/// SynthesizeRunner.kt
///
/// Android entry point for the null-input synthesize path (docs/api.md
/// `Video.synthesize` + `VideoRenderController`). Analogous to iOS
/// RNVPSynthesizeRunner (ios/SynthesizeRunner.h/mm) — the two platforms
/// agree on:
///
///   1. Frame count: exactly `round(fps * seconds)` for fixed renders.
///   2. PTS: deterministic `frameIndex / fps`.
///   3. Test-pattern source: flat RGB fill whose triple is a function of
///      frame index only — `(r,g,b) = ((i*11)&0xff, (i*53)&0xff, (i*97)&0xff)`.
///      The same formula lives in iOS `fillTestPatternRGBA` and in
///      `__tests__/bootstrap/self-test.ts`; if you touch it here, update
///      all three. This is the v0.1 placeholder for the eventual worklet
///      pump (post-v0.1 compose task — see SynthesizeRunner.mm:9-12).
///   4. StopToken semantics: `requestFinish` finalises the output after
///      the current frame; `requestAbort` deletes the partial file and
///      surfaces an aborted flag. `finish` is a no-op on the fixed path
///      (matches iOS line 86-88 and the VideoRenderController policy).
///
/// Frame delivery goes through VideoEncoder, which wraps MediaCodec +
/// MediaMuxer + an EGL14 context on the encoder's input Surface. A flat
/// glClearColor + glClear is sufficient for the test pattern since every
/// pixel is the same value; the worklet pump will upload a real RGBA
/// buffer as a GL texture when it lands.
///

package com.margelo.nitro.videopipeline

import java.io.File

internal object SynthesizeRunner {

  data class FixedResult(val framesWritten: Int, val aborted: Boolean)
  data class OpenResult(
    val framesWritten: Int,
    val aborted: Boolean,
    val hitMaxSeconds: Boolean,
  )

  /// Functional type matching iOS RNVPProgressBlock: (framesCompleted,
  /// nbFrames?, elapsedMs, etaMs?) -> Unit. nulls encode the two
  /// std::optional fields. Coalesced to ≥10 Hz inside the runner.
  fun interface ProgressSink {
    fun report(
      framesCompleted: Int,
      nbFrames: Int?,
      elapsedMs: Double,
      estimatedRemainingMs: Double?,
    )
  }

  /// Thrown when the caller-supplied spec is invalid. Mirrors iOS
  /// RNVPSynthesizeRunnerErrorCodeInvalidSpec. Message shape matches the
  /// `VideoPipeline.render synthesize failed: ...` prefix that
  /// HybridVideoPipeline.render wraps around the final rejection.
  class InvalidSpecException(message: String) : IllegalArgumentException(message)

  fun runFixed(
    outputPath: String,
    width: Int,
    height: Int,
    fps: Double,
    seconds: Double,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
  ): FixedResult {
    if (outputPath.isEmpty() || width <= 0 || height <= 0 || fps <= 0.0 || seconds <= 0.0) {
      throw InvalidSpecException(
        "synthesize: invalid spec (outputPath=$outputPath, " +
          "size=${width}x$height, fps=$fps, seconds=$seconds)"
      )
    }

    // MediaMuxer refuses to overwrite an existing file; VideoEncoder.open
    // also does the delete but doing it here too keeps the on-error path
    // symmetric with iOS (RNVPSynthesizeRunner line 272-275).
    File(outputPath).apply { if (exists()) delete() }

    val frameCount = VideoEncoder.frameCountFor(fps, seconds)
    if (frameCount <= 0) {
      throw InvalidSpecException(
        "synthesize: computed frame count is 0 for fps=$fps, seconds=$seconds"
      )
    }

    val fpsInt = fps.coerceAtLeast(1.0).toInt().coerceAtLeast(1)
    val encoder = VideoEncoder.open(outputPath, width, height, fpsInt)
    val startNanos = System.nanoTime()

    // Seed the progress UI with a definite nbFrames so bars can size
    // themselves before the first frame (mirrors iOS line 307-324).
    progress?.report(0, frameCount, 0.0, (frameCount.toDouble() / fps) * 1000.0)
    var lastProgressMs = 0.0

    try {
      var i = 0
      while (i < frameCount) {
        // Fixed path: poll abort only — finish() is a no-op here per
        // VideoRenderController's policy (controller policy; ios/SynthesizeRunner.mm:86-88).
        if (stopToken?.isAbortRequested() == true) {
          encoder.abort()
          progress?.report(i, frameCount, elapsedMsSince(startNanos), 0.0)
          return FixedResult(framesWritten = i, aborted = true)
        }
        val (r, g, b) = patternForFrame(i)
        val ptsNs = ((i.toDouble() / fps) * 1_000_000_000.0).toLong()
        encoder.writeFlatFrame(r, g, b, ptsNs)
        val framesCompleted = i + 1
        val elapsedMs = elapsedMsSince(startNanos)
        if (
          progress != null &&
          (framesCompleted == frameCount || elapsedMs - lastProgressMs >= COALESCE_MS)
        ) {
          val remaining = (frameCount - framesCompleted).coerceAtLeast(0)
          val etaMs = if (framesCompleted > 0) {
            elapsedMs / framesCompleted * remaining
          } else 0.0
          progress.report(framesCompleted, frameCount, elapsedMs, etaMs)
          lastProgressMs = elapsedMs
        }
        i++
      }
      encoder.finish()
      return FixedResult(framesWritten = frameCount, aborted = false)
    } catch (t: Throwable) {
      encoder.abort()
      throw t
    }
  }

  fun runOpen(
    outputPath: String,
    width: Int,
    height: Int,
    fps: Double,
    maxSeconds: Double,
    stopToken: VideoPipelineStopToken,
    progress: ProgressSink?,
  ): OpenResult {
    if (outputPath.isEmpty() || width <= 0 || height <= 0 || fps <= 0.0) {
      throw InvalidSpecException(
        "synthesize: invalid open spec (outputPath=$outputPath, " +
          "size=${width}x$height, fps=$fps)"
      )
    }

    File(outputPath).apply { if (exists()) delete() }

    val fpsInt = fps.coerceAtLeast(1.0).toInt().coerceAtLeast(1)
    val encoder = VideoEncoder.open(outputPath, width, height, fpsInt)
    val startNanos = System.nanoTime()

    // Open-ended renders don't know the total until finish() fires, so the
    // initial tick carries null for both nbFrames and ETA — matches iOS
    // line 412-429 and docs/api.md "undefined for open-ended renders until
    // finish() is called".
    progress?.report(0, null, 0.0, null)
    var lastProgressMs = 0.0

    var i = 0
    var hitMax = false
    try {
      while (true) {
        if (stopToken.isAbortRequested()) {
          encoder.abort()
          progress?.report(i, null, elapsedMsSince(startNanos), null)
          return OpenResult(framesWritten = i, aborted = true, hitMaxSeconds = false)
        }
        // Finish is checked BEFORE producing the next frame so the last
        // PTS doesn't overshoot maxSeconds (iOS ComposeRunner does the
        // same ordering — see cpp/compose/ComposeRunner.cpp).
        if (stopToken.isFinishRequested()) break
        val ptsSec = i / fps
        if (maxSeconds > 0.0 && ptsSec >= maxSeconds) {
          hitMax = true
          break
        }
        val (r, g, b) = patternForFrame(i)
        val ptsNs = (ptsSec * 1_000_000_000.0).toLong()
        encoder.writeFlatFrame(r, g, b, ptsNs)
        val framesCompleted = i + 1
        val elapsedMs = elapsedMsSince(startNanos)
        if (progress != null && elapsedMs - lastProgressMs >= COALESCE_MS) {
          progress.report(framesCompleted, null, elapsedMs, null)
          lastProgressMs = elapsedMs
        }
        i++
      }
      encoder.finish()
      val elapsedMs = elapsedMsSince(startNanos)
      progress?.report(i, i, elapsedMs, 0.0)
      return OpenResult(framesWritten = i, aborted = false, hitMaxSeconds = hitMax)
    } catch (t: Throwable) {
      encoder.abort()
      throw t
    }
  }

  private const val COALESCE_MS = 100.0

  private fun patternForFrame(frameIndex: Int): Triple<Int, Int, Int> {
    val r = (frameIndex * 11) and 0xff
    val g = (frameIndex * 53) and 0xff
    val b = (frameIndex * 97) and 0xff
    return Triple(r, g, b)
  }

  private fun elapsedMsSince(startNanos: Long): Double {
    return (System.nanoTime() - startNanos) / 1_000_000.0
  }
}
