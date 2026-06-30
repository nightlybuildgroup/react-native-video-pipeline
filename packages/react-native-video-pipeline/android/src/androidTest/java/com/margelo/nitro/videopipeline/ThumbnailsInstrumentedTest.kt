///
/// ThumbnailsInstrumentedTest.kt
///
/// Instrumented coverage for the Android batch frame-extraction path
/// ([ProbeRunner.thumbnails], #73) — N frames from a single
/// MediaMetadataRetriever decode session, mapped back to caller order, with
/// partial-success and validation semantics. The single-frame `thumbnail`
/// shares the same per-frame helper, so this also exercises that code path.
///
/// Fixtures are authored on-device via SynthesizeRunner (no committed binary
/// video, per the test-fixture invariant).
///

package com.margelo.nitro.videopipeline

import android.content.Context
import android.graphics.BitmapFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class ThumbnailsInstrumentedTest {

  private val ctx: Context
    get() = InstrumentationRegistry.getInstrumentation().targetContext

  private val width = 160
  private val height = 120
  private val fps = 30
  private val frameCount = 30 // 1.0s

  private fun synthFixture(tag: String): String {
    val f = File(ctx.cacheDir, "thumbs-src-$tag.mp4")
    f.delete()
    SynthesizeRunner.runFixed(
      outputPath = f.absolutePath,
      width = width,
      height = height,
      fps = fps.toDouble(),
      seconds = frameCount / fps.toDouble(),
      stopToken = null,
      progress = null,
    )
    assertTrue("synth fixture authored", f.exists() && f.length() > 0)
    return f.absolutePath
  }

  private fun outPaths(tag: String, count: Int): List<String> =
    (0 until count).map { i ->
      File(ctx.cacheDir, "thumbs-$tag-$i.jpg").also { it.delete() }.absolutePath
    }

  /// Is this file a JPEG? Decode the bounds and confirm dimensions are sane.
  private fun jpegSize(path: String): Pair<Int, Int> {
    val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(path, opts)
    return opts.outWidth to opts.outHeight
  }

  @Test
  fun batchGeneratesAllFramesInCallerOrder() {
    val src = synthFixture("all")
    val times = listOf(0.0, 0.25, 0.5, 0.75)
    val outs = outPaths("all", times.size)

    val result = ProbeRunner.thumbnails(
      uri = src,
      atSecs = times,
      outPaths = outs,
      resizeW = 0.0,
      resizeH = 0.0,
      toleranceSec = 0.0,
    )

    assertEquals(times.size, result.size)
    for (i in times.indices) {
      assertEquals(outs[i], result[i])
      val f = File(outs[i])
      assertTrue("frame $i written", f.exists() && f.length() > 0)
      val (w, h) = jpegSize(outs[i])
      assertEquals(160, w)
      assertEquals(120, h)
    }
  }

  @Test
  fun batchMapsUnsortedTimesToCallerOrder() {
    val src = synthFixture("unsorted")
    val times = listOf(0.75, 0.0, 0.5, 0.25)
    val outs = outPaths("unsorted", times.size)

    val result = ProbeRunner.thumbnails(
      uri = src,
      atSecs = times,
      outPaths = outs,
      resizeW = 0.0,
      resizeH = 0.0,
      toleranceSec = 0.0,
    )

    assertEquals(times.size, result.size)
    for (i in times.indices) {
      assertEquals(outs[i], result[i])
      assertTrue("frame $i written", File(outs[i]).exists())
    }
  }

  @Test
  fun batchToleranceAndResizeApplyToAll() {
    val src = synthFixture("tol")
    val times = listOf(0.1, 0.4, 0.9)
    val outs = outPaths("tol", times.size)

    val result = ProbeRunner.thumbnails(
      uri = src,
      atSecs = times,
      outPaths = outs,
      resizeW = 80.0,
      resizeH = 0.0,
      toleranceSec = 0.5, // OPTION_CLOSEST_SYNC — nearest keyframe
    )

    assertEquals(times.size, result.size)
    for (i in times.indices) {
      assertTrue("slot $i non-empty", result[i].isNotEmpty())
      val (w, h) = jpegSize(outs[i])
      assertEquals(80, w)
      assertEquals(60, h)
    }
  }

  @Test(expected = ProbeRunner.InvalidSpecException::class)
  fun batchRejectsMismatchedArrays() {
    val src = synthFixture("mismatch")
    ProbeRunner.thumbnails(
      uri = src,
      atSecs = listOf(0.0, 0.5),
      outPaths = listOf(File(ctx.cacheDir, "thumbs-mismatch.jpg").absolutePath),
      resizeW = 0.0,
      resizeH = 0.0,
      toleranceSec = 0.0,
    )
  }

  @Test(expected = ProbeRunner.InvalidSpecException::class)
  fun batchRejectsEmptyTimes() {
    val src = synthFixture("empty")
    ProbeRunner.thumbnails(
      uri = src,
      atSecs = emptyList(),
      outPaths = emptyList(),
      resizeW = 0.0,
      resizeH = 0.0,
      toleranceSec = 0.0,
    )
  }

  @Test(expected = ProbeRunner.NotFoundException::class)
  fun batchRejectsMissingSource() {
    val ghost = File(ctx.cacheDir, "thumbs-ghost.mp4").also { it.delete() }.absolutePath
    ProbeRunner.thumbnails(
      uri = ghost,
      atSecs = listOf(0.0, 0.5),
      outPaths = outPaths("ghost", 2),
      resizeW = 0.0,
      resizeH = 0.0,
      toleranceSec = 0.0,
    )
  }
}
