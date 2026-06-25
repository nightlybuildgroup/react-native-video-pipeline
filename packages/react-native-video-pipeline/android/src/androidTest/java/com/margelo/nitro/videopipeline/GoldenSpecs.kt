///
/// GoldenSpecs.kt
///
/// The golden render specs, kept in lockstep with the iOS side
/// (ios/__tests__/LibraryTests.m `golden_*`) and the host orchestrator
/// (scripts/golden.mjs GOLDEN_SPECS). Any change here must be mirrored in both
/// or the cross-platform comparison breaks. Frame sampling targets
/// `(frame + 0.5) / fps` so OPTION_CLOSEST lands squarely on the intended
/// frame on both platforms (output PTS is always frameIndex/fps).
///

package com.margelo.nitro.videopipeline

internal data class GoldenSpec(
  val id: String,
  val width: Int,
  val height: Int,
  val fps: Double,
  val seconds: Double,
  val sampleFrames: List<Int>,
)

internal object GoldenSpecs {
  val ALL = listOf(
    GoldenSpec(
      id = "synthesize",
      width = 160,
      height = 120,
      fps = 30.0,
      seconds = 0.5,
      sampleFrames = listOf(5, 10, 14),
    ),
  )
}
