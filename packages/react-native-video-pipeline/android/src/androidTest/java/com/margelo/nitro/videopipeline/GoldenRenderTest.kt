///
/// GoldenRenderTest.kt
///
/// T048 — Android half of the cross-platform golden pixel-hash suite. Renders
/// the deterministic `synthesize` golden spec via `SynthesizeRunner.runFixed`
/// (the built-in flat-fill pattern `(i*11, i*53, i*97) & 0xff`, which is
/// byte-identical to the iOS SynthesizeRunner pattern — so the two platforms
/// produce the same content before encoding), then extracts a fixed set of
/// sampled frames as raw RGBA8888 and writes them where the host
/// `scripts/golden.mjs` orchestrator can pull them.
///
/// This test is NOT a pass/fail assertion of parity — it only produces the
/// per-platform frame dumps. The host script computes the low-res signatures
/// and does the regression + cross-platform comparison (one canonical hash
/// impl for both platforms). The test asserts only that rendering + extraction
/// succeeded.
///
/// Output: raw `<spec>__<w>x<h>__f<frame>.rgba` files under
/// `Download/rnvp-golden/` via MediaStore (survives the test-APK uninstall,
/// pullable from `/sdcard/Download/rnvp-golden/`).
///

package com.margelo.nitro.videopipeline

import android.content.ContentValues
import android.content.Context
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class GoldenRenderTest {

  private val ctx: Context
    get() = InstrumentationRegistry.getInstrumentation().targetContext

  @Test
  fun renderGoldenFramesIntoDownloads() {
    require(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      "golden render harness targets API 29+ (MediaStore.Downloads); device is ${Build.VERSION.SDK_INT}"
    }
    for (spec in GoldenSpecs.ALL) {
      val src = File(ctx.cacheDir, "golden-${spec.id}.mp4")
      src.delete()
      SynthesizeRunner.runFixed(
        outputPath = src.absolutePath,
        width = spec.width,
        height = spec.height,
        fps = spec.fps,
        seconds = spec.seconds,
        stopToken = null,
        progress = null,
      )
      assertTrue("rendered ${spec.id}", src.exists() && src.length() > 0)

      val retriever = MediaMetadataRetriever()
      try {
        retriever.setDataSource(src.absolutePath)
        for (frame in spec.sampleFrames) {
          // getFrameAtIndex keys on the exact 0-based frame index (API 28+) —
          // unlike getFrameAtTime it has no time-tolerance ambiguity, so it
          // lands on the same frame the iOS AVAssetReader walk does.
          val bmp = retriever.getFrameAtIndex(frame)
          assertNotNull("frame $frame of ${spec.id}", bmp)
          val rgba = bmp!!.toRgbaBytes()
          writeToDownloads("${spec.id}__${bmp.width}x${bmp.height}__f$frame.rgba", rgba)
        }
      } finally {
        retriever.release()
      }
    }
  }

  /// ARGB_8888 Bitmap → tightly-packed RGBA byte array (R,G,B,A per pixel).
  private fun android.graphics.Bitmap.toRgbaBytes(): ByteArray {
    val pixels = IntArray(width * height)
    getPixels(pixels, 0, width, 0, 0, width, height)
    val out = ByteArray(width * height * 4)
    var o = 0
    for (p in pixels) {
      out[o++] = ((p shr 16) and 0xFF).toByte() // R
      out[o++] = ((p shr 8) and 0xFF).toByte()  // G
      out[o++] = (p and 0xFF).toByte()          // B
      out[o++] = ((p shr 24) and 0xFF).toByte() // A
    }
    return out
  }

  private fun writeToDownloads(name: String, bytes: ByteArray) {
    val resolver = ctx.contentResolver
    // Replace any prior copy (including MediaStore's " (1)" collision variants
    // from earlier runs) so reruns produce exactly one file per name.
    val base = name.removeSuffix(".rgba")
    resolver.delete(
      MediaStore.Downloads.EXTERNAL_CONTENT_URI,
      "${MediaStore.Downloads.DISPLAY_NAME} LIKE ?",
      arrayOf("$base%"),
    )
    val values = ContentValues().apply {
      put(MediaStore.Downloads.DISPLAY_NAME, name)
      put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
      put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/rnvp-golden/")
    }
    val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)!!
    resolver.openOutputStream(uri)!!.use { it.write(bytes) }
  }
}
