///
/// TextOverlayInstrumentedTest.kt
///
/// On-device verification of the T045 Android text-overlay path. Runs on the
/// emulator/device (Paint/Canvas/StaticLayout + MediaCodec are not available on
/// the host JVM). Lives in the library module so it can reach the `internal`
/// `Transcoder` / `OverlayTextRasterizer` / `SynthesizeRunner` surface.
///
/// Coverage:
///   * `OverlayTextRasterizer.parseColor` — hex (alpha-last) + rgb()/rgba().
///   * `OverlayTextRasterizer.rasterize` — produces a non-empty bitmap with
///     actually-drawn glyph pixels; rejects malformed colors.
///   * `Transcoder` end-to-end — a synthesized source MP4 stamped with a text
///     overlay re-encodes to a decodable MP4 with a video track.
///

package com.margelo.nitro.videopipeline

import android.media.MediaExtractor
import android.media.MediaFormat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class TextOverlayInstrumentedTest {

  private fun cacheDir(): File =
    InstrumentationRegistry.getInstrumentation().targetContext.cacheDir

  private fun textStyle(
    color: String = "#ffffff",
    fontSize: Double = 32.0,
    weight: FontWeight? = null,
    align: TextAlign? = null,
    shadow: TextShadow? = null,
  ) = TextStyle(
    fontFamily = null,
    fontSize = fontSize,
    color = color,
    weight = weight,
    align = align,
    shadow = shadow,
  )

  private fun textOverlay(
    text: String = "RNVP",
    style: TextStyle = textStyle(),
  ) = TextOverlay(
    kind = OverlayKind.TEXT,
    text = text,
    style = style,
    anchor = AnchorPoint(0.5, 0.5),
    timeRange = null,
  )

  @Test
  fun parseColor_handlesHexAndRgbForms() {
    // 3 / 4 / 6 / 8 digit hex — alpha LAST (matches iOS). Short-form nibbles
    // expand by duplication, so "#f008" → alpha 0x88 (8*17), not 0x80.
    assertEquals(0xFFFF0000.toInt(), OverlayTextRasterizer.parseColor("#f00"))
    assertEquals(0x88FF0000.toInt(), OverlayTextRasterizer.parseColor("#f008"))
    assertEquals(0xFF00FF00.toInt(), OverlayTextRasterizer.parseColor("#00ff00"))
    assertEquals(0x800000FF.toInt(), OverlayTextRasterizer.parseColor("#0000ff80"))
    // rgb() / rgba() — channels 0..255, alpha 0..1.
    assertEquals(0xFF0000FF.toInt(), OverlayTextRasterizer.parseColor("rgb(0, 0, 255)"))
    assertEquals(0x8000FF00.toInt(), OverlayTextRasterizer.parseColor("rgba(0,255,0,0.5)"))
  }

  @Test
  fun parseColor_rejectsMalformed() {
    assertNull(OverlayTextRasterizer.parseColor(""))
    assertNull(OverlayTextRasterizer.parseColor("#gg"))
    assertNull(OverlayTextRasterizer.parseColor("#12345"))
    assertNull(OverlayTextRasterizer.parseColor("hsl(0,0,0)"))
    assertNull(OverlayTextRasterizer.parseColor("rgb(1,2)"))
  }

  @Test
  fun rasterize_drawsVisibleGlyphPixels() {
    val bitmap = OverlayTextRasterizer.rasterize(
      textOverlay(
        text = "Hello",
        style = textStyle(fontSize = 48.0, weight = FontWeight.BOLD, align = TextAlign.CENTER),
      ),
    )
    assertTrue("bitmap has positive dimensions", bitmap.width > 0 && bitmap.height > 0)
    val pixels = IntArray(bitmap.width * bitmap.height)
    bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
    val opaque = pixels.count { (it ushr 24) != 0 }
    assertTrue("expected rendered glyph pixels, found none", opaque > 0)
  }

  @Test(expected = Transcoder.InvalidSpecException::class)
  fun rasterize_rejectsMalformedColor() {
    OverlayTextRasterizer.rasterize(textOverlay(style = textStyle(color = "not-a-color")))
  }

  @Test
  fun textStamp_reEncodesToPlayableMp4() {
    val dir = cacheDir()
    val src = File(dir, "rnvp-text-src.mp4")
    val out = File(dir, "rnvp-text-stamped.mp4")
    src.delete()
    out.delete()

    // Source: built-in synthesize pattern — no JS worklet needed.
    SynthesizeRunner.runFixed(
      outputPath = src.absolutePath,
      width = 160,
      height = 120,
      fps = 30.0,
      seconds = 0.4,
      stopToken = null,
      progress = null,
    )
    assertTrue("synthesized source exists", src.exists() && src.length() > 0)

    val resolved = Transcoder.resolveTextOverlay(
      textOverlay(
        text = "RNVP",
        style = textStyle(
          color = "#ffcc00",
          fontSize = 24.0,
          shadow = TextShadow(color = "#000000", blur = 2.0, dx = 1.0, dy = 1.0),
        ),
      ),
    )
    val target = Transcoder.Target(
      width = 160,
      height = 120,
      fps = 30.0,
      codec = Transcoder.Codec.H264,
      bitrate = 0,
      rotate = -1,
      flipH = false,
      flipV = false,
      cropX = 0.0,
      cropY = 0.0,
      cropWidth = 0.0,
      cropHeight = 0.0,
    )

    val result = Transcoder.transcode(
      sourceUri = "file://${src.absolutePath}",
      outputPath = out.absolutePath,
      target = target,
      overlays = listOf(resolved),
      metadata = null,
      stopToken = null,
      progress = null,
    )
    assertFalse("transcode should not abort", result.aborted)
    assertTrue("transcode wrote frames", result.framesWritten > 0)
    assertTrue("stamped output exists", out.exists() && out.length() > 0)

    // The output must be a demuxable MP4 carrying a video track.
    val extractor = MediaExtractor()
    try {
      extractor.setDataSource(out.absolutePath)
      var hasVideo = false
      for (i in 0 until extractor.trackCount) {
        val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
        if (mime.startsWith("video/")) hasVideo = true
      }
      assertTrue("stamped output has a video track", hasVideo)
    } finally {
      extractor.release()
    }
  }
}
