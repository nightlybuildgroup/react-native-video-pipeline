///
/// Mp4MetadataInjectorInstrumentedTest.kt
///
/// Instrumented coverage for the post-encode MP4 metadata patcher. Fixtures are
/// authored on-device via SynthesizeRunner (a real, MediaMuxer-written moov), so
/// the injector runs against the exact box layout production hits.
///
/// Focus: the shrink path (#20). Re-stamping with a *smaller* metadata payload
/// used to throw ("shrinking is not implemented"); it must now succeed without
/// corrupting the file — chunk offsets (stco/co64) stay valid, so the video
/// still decodes after the rewrite.
///

package com.margelo.nitro.videopipeline

import android.media.MediaMetadataRetriever
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class Mp4MetadataInjectorInstrumentedTest {

  private val ctx
    get() = InstrumentationRegistry.getInstrumentation().targetContext

  private fun synthFixture(tag: String): String {
    val f = File(ctx.cacheDir, "mdta-src-$tag.mp4")
    f.delete()
    SynthesizeRunner.runFixed(
      outputPath = f.absolutePath,
      width = 160,
      height = 120,
      fps = 30.0,
      seconds = 1.0,
      stopToken = null,
      progress = null,
    )
    assertTrue("synth fixture authored", f.exists() && f.length() > 0)
    return f.absolutePath
  }

  /// First decoded frame + duration, used to prove the video stream is still
  /// intact (offsets uncorrupted) after a metadata rewrite.
  private fun assertStillDecodes(path: String) {
    val r = MediaMetadataRetriever()
    try {
      r.setDataSource(path)
      val durMs = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
      assertTrue("duration ~1.0s (got ${durMs}ms)", abs(durMs - 1000L) < 250L)
      assertNotNull("frame 0 decodes (offsets intact)", r.getFrameAtIndex(0))
    } finally {
      runCatching { r.release() }
    }
  }

  /// Re-stamping with a smaller payload than the previous stamp must succeed and
  /// leave a readable, uncorrupted file. This is the #20 regression: the second
  /// inject shrinks the moov relative to the first.
  @Test
  fun reinjectWithSmallerPayloadShrinksWithoutCorruption() {
    val path = synthFixture("shrink")

    // First stamp: a large payload, so the moov grows well past its muxed size.
    val big = mapOf(
      "com.test.note" to "x".repeat(4096),
      "com.test.extra" to "y".repeat(2048),
    )
    Mp4MetadataInjector.inject(path, big)
    assertEquals("large payload round-trips", big, Mp4MetadataInjector.read(path).filterKeys { it in big.keys })
    assertStillDecodes(path)
    val sizeAfterBig = File(path).length()

    // Second stamp: a much smaller payload + one fewer key → the rewritten moov
    // is smaller than what's on disk. Previously this threw.
    val small = mapOf("com.test.note" to "tiny")
    Mp4MetadataInjector.inject(path, small)

    val readBack = Mp4MetadataInjector.read(path)
    assertEquals("smaller payload round-trips", "tiny", readBack["com.test.note"])
    assertTrue(
      "stale key from the larger stamp is gone",
      !readBack.containsKey("com.test.extra"),
    )
    assertStillDecodes(path)
    assertTrue(
      "shrink did not grow the file (got $sizeAfterBig -> ${File(path).length()})",
      File(path).length() <= sizeAfterBig,
    )
  }

  /// A tiny shrink (1..7 bytes) can't be expressed as a standalone free box, so
  /// padMoovToNoShrink overshoots by a few bytes and the standard grow path
  /// runs. Exercise a value one character shorter to land in that window.
  @Test
  fun reinjectOneByteSmallerStillRoundTrips() {
    val path = synthFixture("tiny-shrink")
    Mp4MetadataInjector.inject(path, mapOf("com.test.k" to "aaaaaaaa"))
    assertStillDecodes(path)
    // One UTF-8 byte shorter — a single-byte moov shrink.
    Mp4MetadataInjector.inject(path, mapOf("com.test.k" to "aaaaaaa"))
    assertEquals("aaaaaaa", Mp4MetadataInjector.read(path)["com.test.k"])
    assertStillDecodes(path)
  }
}
