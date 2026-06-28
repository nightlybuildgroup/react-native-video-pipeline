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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.time.Instant
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

  /// #25: the full MetadataSpec (not just location) must survive a stamp and
  /// read back through ProbeRunner — software in custom, description +
  /// creationDate in their dedicated fields, custom verbatim, location via the
  /// muxer. End-to-end: synthesize -> remuxStamp -> info.
  @Test
  fun stampPersistsFullMetadataSpecForProbe() {
    val src = synthFixture("full-spec")
    val out = File(ctx.cacheDir, "mdta-full-spec-out.mp4").absolutePath

    val created = Instant.parse("2026-04-24T12:34:56Z")
    val metadata = MetadataSpec(
      location = WGS84Coordinate(latitude = 48.8584, longitude = 2.2945, altitude = null),
      software = "react-native-video-pipeline-test",
      creationDate = created,
      description = "a stamped clip",
      custom = mapOf("com.acme.shot" to "B-roll 7"),
    )
    Remuxer.remuxStamp(sourceUri = src, outputPath = out, metadata = metadata)

    val info = ProbeRunner.info(out)
    assertEquals("description round-trips", "a stamped clip", info.description)
    assertEquals("creationDate round-trips", created, info.creationDate)
    val custom = info.custom ?: emptyMap()
    assertEquals("software surfaces in custom", "react-native-video-pipeline-test", custom["software"])
    assertEquals("custom key round-trips", "B-roll 7", custom["com.acme.shot"])
    assertNull("description not duplicated into custom", custom["description"])
    assertNull("creationDate not duplicated into custom", custom["creationDate"])
    assertNotNull("location persisted via setLocation", info.location)
    val loc = info.location!!
    assertTrue("latitude ~48.8584 (got ${loc.latitude})", abs(loc.latitude - 48.8584) < 0.01)
    assertTrue("longitude ~2.2945 (got ${loc.longitude})", abs(loc.longitude - 2.2945) < 0.01)
  }

  /// Injector-level: injectSpec writes the canonical mdta keys read() exposes.
  @Test
  fun injectSpecWritesCanonicalKeys() {
    val path = synthFixture("inject-spec")
    Mp4MetadataInjector.injectSpec(
      path,
      MetadataSpec(
        location = null,
        software = "sw",
        creationDate = Instant.parse("2026-01-02T03:04:05Z"),
        description = "desc",
        custom = mapOf("com.acme.k" to "v"),
      ),
    )
    val items = Mp4MetadataInjector.read(path)
    assertEquals("sw", items[Mp4MetadataInjector.KEY_SOFTWARE])
    assertEquals("desc", items[Mp4MetadataInjector.KEY_DESCRIPTION])
    assertEquals("2026-01-02T03:04:05Z", items[Mp4MetadataInjector.KEY_CREATION_DATE])
    assertEquals("v", items["com.acme.k"])
  }

  /// A caller-authored custom key that collides with the canonical
  /// `creationDate` key but isn't a parseable date must survive the probe
  /// round-trip in `custom` (caller owns their keys), not be silently consumed
  /// by the dedicated-field mapping.
  @Test
  fun unparseableCreationDateCustomKeyStaysInCustom() {
    val path = synthFixture("bad-date")
    Mp4MetadataInjector.inject(path, mapOf(Mp4MetadataInjector.KEY_CREATION_DATE to "not-a-date"))
    val info = ProbeRunner.info(path)
    assertEquals(
      "non-date custom value preserved in custom",
      "not-a-date",
      (info.custom ?: emptyMap())[Mp4MetadataInjector.KEY_CREATION_DATE],
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
