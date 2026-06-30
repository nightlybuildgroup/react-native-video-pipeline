///
/// OutputPathInstrumentedTest.kt
///
/// Instrumented coverage for `outputFilesystemPath` (issue #78 — the Android
/// parity for iOS #74). `output.path` must accept both a bare filesystem path
/// and a `file://` URI (e.g. expo-file-system's `File.uri`); the URI must be
/// stripped to its bare, percent-decoded path before reaching MediaMuxer /
/// Media3 / `File(...)`, or the export fails to create the file.
///
/// Uses `android.net.Uri`, which is only real under instrumentation (it throws
/// in plain JVM unit tests), so this must be an instrumented test. The end-to-
/// end case drives the real encode pipeline via SynthesizeRunner.
///

package com.margelo.nitro.videopipeline

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class OutputPathInstrumentedTest {

  private val ctx: Context
    get() = InstrumentationRegistry.getInstrumentation().targetContext

  @Test
  fun barePathPassesThrough() {
    val bare = "/data/local/tmp/rnvp/out.mp4"
    assertEquals(bare, outputFilesystemPath(bare))
  }

  @Test
  fun fileUriIsStrippedToBarePath() {
    val posix = "/data/local/tmp/rnvp/out.mp4"
    val uri = Uri.fromFile(File(posix)).toString() // file:///data/local/tmp/rnvp/out.mp4
    assertTrue("sanity: built a file:// URI", uri.startsWith("file://"))
    assertEquals(posix, outputFilesystemPath(uri))
  }

  @Test
  fun percentEncodedFileUriIsDecoded() {
    // expo-file-system percent-encodes spaces in File.uri; the bare path must
    // come back decoded so File(...) / the muxer can create it.
    val posix = "/data/local/tmp/rnvp dir/my out.mp4"
    val uri = Uri.fromFile(File(posix)).toString()
    assertTrue("sanity: spaces are encoded as %20", uri.contains("%20"))
    assertEquals(posix, outputFilesystemPath(uri))
  }

  @Test
  fun emptyInputIsUnchanged() {
    assertEquals("", outputFilesystemPath(""))
  }

  /// End-to-end: synthesize to a `file://` URI `output.path` (with a space in
  /// the directory, to exercise percent-decoding) and assert a valid MP4 lands
  /// at the decoded bare path — the exact #78 failure mode, now fixed.
  @Test
  fun synthesizeWritesValidMp4ToNormalizedFileUri() {
    val dir = File(ctx.cacheDir, "rnvp out 78").apply { mkdirs() }
    val posix = File(dir, "synth.mp4").absolutePath
    val uri = Uri.fromFile(File(posix)).toString()
    assertTrue(uri.startsWith("file://"))
    File(posix).delete()

    val normalized = outputFilesystemPath(uri)
    assertEquals(posix, normalized)

    SynthesizeRunner.runFixed(
      outputPath = normalized,
      width = 160,
      height = 120,
      fps = 30.0,
      seconds = 0.5,
      stopToken = null,
      progress = null,
    )

    val out = File(posix)
    assertTrue("MP4 must exist at the decoded bare path $posix", out.exists())
    assertTrue("MP4 must be non-empty", out.length() > 0)

    val retriever = MediaMetadataRetriever()
    try {
      retriever.setDataSource(posix)
      val hasVideo = retriever.extractMetadata(
        MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO,
      )
      assertEquals("normalized-path output should be a valid video", "yes", hasVideo)
    } finally {
      retriever.release()
      out.delete()
    }
  }
}
