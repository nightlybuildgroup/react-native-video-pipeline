///
/// VideoPipelineStopToken.kt
///
/// Android analogue of iOS RNVPStopToken (ios/SynthesizeRunner.h) and the
/// cross-platform cpp/compose/StopToken.hpp. Two terminal states:
///   - requestFinish — stop after the current frame, finalize output
///     (mirrors controller.finish() / ctx.finish()).
///   - requestAbort  — stop immediately, discard output
///     (mirrors controller.abort() / AbortSignal).
///
/// `abort` wins over `finish` once requested. Both transitions are one-way
/// and idempotent. Uses AtomicBoolean so a background render loop can poll
/// the flags without a mutex on every frame.
///

package com.margelo.nitro.videopipeline

import java.util.concurrent.atomic.AtomicBoolean

class VideoPipelineStopToken {
  private val finishFlag = AtomicBoolean(false)
  private val abortFlag = AtomicBoolean(false)

  fun requestFinish() {
    finishFlag.set(true)
  }

  fun requestAbort() {
    abortFlag.set(true)
  }

  fun isFinishRequested(): Boolean = finishFlag.get()

  fun isAbortRequested(): Boolean = abortFlag.get()
}
