///
/// RenderTransformInstrumentedTest.kt
///
/// Instrumented coverage for the Android render-with-transform path, which runs
/// on Media3 Transformer ([TransformerRunner]). Mirrors the iOS XCTests
/// testRemuxTransformTrim* / testTranscodeTrimWindowProducesWindowedOutput.
///
/// Fixtures are authored on-device: video via SynthesizeRunner (the golden
/// flat-fill pattern, distinct per frame), audio via a generated silent AAC
/// track muxed alongside the video so the audio-passthrough path has something
/// to copy.
///

package com.margelo.nitro.videopipeline

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.roundToInt

@RunWith(AndroidJUnit4::class)
class RenderTransformInstrumentedTest {

  private val ctx: Context
    get() = InstrumentationRegistry.getInstrumentation().targetContext

  private val width = 160
  private val height = 120
  private val fps = 30
  private val frameCount = 30 // 1.0s

  private fun synthFixture(tag: String): String {
    val f = File(ctx.cacheDir, "xform-src-$tag.mp4")
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

  private fun durationSec(path: String): Double {
    val r = MediaMetadataRetriever()
    return try {
      r.setDataSource(path)
      (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) / 1000.0
    } finally {
      runCatching { r.release() }
    }
  }

  private fun dimensions(path: String): Pair<Int, Int> {
    val r = MediaMetadataRetriever()
    return try {
      r.setDataSource(path)
      val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)!!.toInt()
      val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)!!.toInt()
      Pair(w, h)
    } finally {
      runCatching { r.release() }
    }
  }

  /// Displayed dimensions of the first decoded frame — accounts for rotation
  /// whether it lives in the container metadata (transmux) or is baked into
  /// pixels (re-encode), unlike METADATA_KEY_VIDEO_WIDTH which reports coded
  /// dimensions on some devices.
  private fun displayedDimensions(path: String): Pair<Int, Int> {
    val r = MediaMetadataRetriever()
    return try {
      r.setDataSource(path)
      val bmp = r.getFrameAtIndex(0) ?: error("no frame 0 in $path")
      Pair(bmp.width, bmp.height)
    } finally {
      runCatching { r.release() }
    }
  }

  /// Counts the video-track samples (= encoded frames) in an MP4 by walking the
  /// extractor. Used to verify frame-rate downsampling drops frames.
  private fun videoFrameCount(path: String): Int {
    val ex = MediaExtractor()
    return try {
      ex.setDataSource(path)
      var track = -1
      for (i in 0 until ex.trackCount) {
        val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
        if (mime.startsWith("video/")) { track = i; break }
      }
      if (track < 0) return 0
      ex.selectTrack(track)
      var n = 0
      while (ex.sampleTime >= 0) {
        n++
        if (!ex.advance()) break
      }
      n
    } finally {
      runCatching { ex.release() }
    }
  }

  /// The center pixel of the first decoded frame. Used to assert an overlay was
  /// actually composited at its anchor.
  private fun centerPixel(path: String): Int {
    val r = MediaMetadataRetriever()
    return try {
      r.setDataSource(path)
      val bmp = r.getFrameAtIndex(0) ?: error("no frame 0 in $path")
      bmp.getPixel(bmp.width / 2, bmp.height / 2)
    } finally {
      runCatching { r.release() }
    }
  }

  private fun trackMimes(path: String): List<String> {
    val ex = MediaExtractor()
    return try {
      ex.setDataSource(path)
      (0 until ex.trackCount).mapNotNull {
        ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)
      }
    } finally {
      runCatching { ex.release() }
    }
  }

  private fun spec(
    src: String,
    out: String,
    rotate: Int = -1,
    flipH: Boolean = false,
    flipV: Boolean = false,
    cropW: Double = 0.0,
    cropH: Double = 0.0,
    startSec: Double = 0.0,
    durationSec: Double = 0.0,
    outWidth: Int? = null,
    outHeight: Int? = null,
    fps: Double? = null,
    removeAudio: Boolean = false,
    audioReplacementUri: String? = null,
    leadingGapSec: Double = 0.0,
  ): TransformerRunner.Spec {
    // Resolve the output canvas exactly as the render router does
    // (HybridVideoPipeline.renderTranscodeSingle): pinned dims win, otherwise
    // the crop rect (or source), swapped for a quarter-turn rotation. This is
    // what makes a single requested dimension fall back on the other axis.
    val swapDims = rotate == 90 || rotate == 270
    val contentW = if (cropW > 0.0) cropW else width.toDouble()
    val contentH = if (cropH > 0.0) cropH else height.toDouble()
    val canvasW = (outWidth?.toDouble() ?: if (swapDims) contentH else contentW).roundToInt()
    val canvasH = (outHeight?.toDouble() ?: if (swapDims) contentW else contentH).roundToInt()
    return TransformerRunner.Spec(
      sourceUri = src,
      outputPath = out,
      sourceWidth = width,
      sourceHeight = height,
      startSec = startSec,
      durationSec = durationSec,
      rotate = rotate,
      flipH = flipH,
      flipV = flipV,
      cropX = 0.0,
      cropY = 0.0,
      cropW = cropW,
      cropH = cropH,
      outWidth = outWidth,
      outHeight = outHeight,
      fps = fps,
      hevc = false,
      bitrate = null,
      outCanvasW = canvasW,
      outCanvasH = canvasH,
      removeAudio = removeAudio,
      audioReplacementUri = audioReplacementUri,
      leadingGapSec = leadingGapSec,
    )
  }

  /// Author a SOLID-colour fixture (every frame the same RGB) so a composited
  /// region can be asserted by channel dominance, robust to the codec's YUV
  /// colour shift. Uses VideoEncoder directly (the synth pattern is per-frame
  /// distinct, which can't separate base from overlay at one time point).
  private fun solidFixture(tag: String, r: Int, g: Int, b: Int, frames: Int = frameCount): String {
    val f = File(ctx.cacheDir, "solid-$tag.mp4")
    f.delete()
    val enc = VideoEncoder.open(f.absolutePath, width, height, fps)
    try {
      for (i in 0 until frames) {
        enc.writeFlatFrame(r, g, b, ((i.toDouble() / fps) * 1_000_000_000.0).toLong())
      }
      enc.finish()
    } catch (t: Throwable) {
      enc.abort()
      throw t
    }
    assertTrue("solid fixture authored", f.exists() && f.length() > 0)
    return f.absolutePath
  }

  /// The pixel at a normalized point (0..1, top-left origin) of the decoded frame
  /// closest to `atSec`. Used to assert a PiP box / crossfade blend at a region.
  private fun pixelAt(path: String, normX: Double, normY: Double, atSec: Double): Int {
    val r = MediaMetadataRetriever()
    return try {
      r.setDataSource(path)
      val bmp = r.getFrameAtTime(
        (atSec * 1_000_000.0).toLong(), MediaMetadataRetriever.OPTION_CLOSEST,
      ) ?: error("no frame at ${atSec}s in $path")
      val x = (normX * (bmp.width - 1)).roundToInt().coerceIn(0, bmp.width - 1)
      val y = (normY * (bmp.height - 1)).roundToInt().coerceIn(0, bmp.height - 1)
      bmp.getPixel(x, y)
    } finally {
      runCatching { r.release() }
    }
  }

  // Multi-track / PiP compositing (#45 — Android parity with iOS #17). A solid
  // BLUE overlay clip is scaled into a bottom-right frame rect and composited on
  // top of a solid RED base over its [0.3s, 0.7s] window. Asserts: during the
  // window the PiP region reads blue and the rest reads the base red; before and
  // after the window the whole frame is the base red. Mirrors the iOS
  // testMultiTrackPipOverlay.
  @Test
  fun multiTrackPipCompositesOverlayOverBase() {
    val base = solidFixture("pip-base", 220, 0, 0) // red
    val pip = solidFixture("pip-over", 0, 0, 220) // blue
    val out = File(ctx.cacheDir, "multi-track-pip.mp4").absolutePath
    File(out).delete()

    val baseSpec = spec(base, out, outWidth = width, outHeight = height)
    // Overlay trimmed to 0.4s, placed at outputStart 0.3s in a 0.3x0.3 box whose
    // centre is the normalized point (0.75, 0.75).
    val overlay = TransformerRunner.OverlayLayer(
      spec = spec(pip, out, outWidth = width, outHeight = height, durationSec = 0.4),
      frameX = 0.6, frameY = 0.6, frameW = 0.3, frameH = 0.3,
      outputStartSec = 0.3, effDurSec = 0.4,
    )
    TransformerRunner.runCompositePip(
      ctx, listOf(baseSpec), listOf(overlay),
      totalDurationSec = frameCount / fps.toDouble(),
      compositionOverlays = emptyList(), stopToken = null, progress = null,
    )
    assertTrue("pip output exists", File(out).exists())
    // Output spans the full base duration (~1.0s), not the overlay window.
    assertEquals(1.0, durationSec(out), 0.25)

    fun isBlue(c: Int) = Color.blue(c) > Color.red(c) + 40 && Color.blue(c) > Color.green(c) + 40
    fun isRed(c: Int) = Color.red(c) > Color.blue(c) + 40 && Color.red(c) > Color.green(c) + 40

    // Mid-window: PiP region blue, opposite corner base red.
    val inPip = pixelAt(out, 0.75, 0.75, 0.5)
    val inBase = pixelAt(out, 0.1, 0.1, 0.5)
    assertTrue("PiP region is blue mid-window (got ${Integer.toHexString(inPip)})", isBlue(inPip))
    assertTrue("base region is red mid-window (got ${Integer.toHexString(inBase)})", isRed(inBase))

    // Before the window: PiP region shows the base.
    val before = pixelAt(out, 0.75, 0.75, 0.1)
    assertTrue("PiP region is base red before window (got ${Integer.toHexString(before)})", isRed(before))
    // After the window: PiP region shows the base again.
    val after = pixelAt(out, 0.75, 0.75, 0.9)
    assertTrue("PiP region is base red after window (got ${Integer.toHexString(after)})", isRed(after))
  }

  // Two overlay tracks at the SAME frame rect over a base — the higher-z overlay
  // must win (drawn on top). Exercises 3-input compositing and the topmost-first
  // sequence registration. Mirrors the iOS ascending-z-order contract.
  @Test
  fun multiTrackPipRespectsZOrderAcrossOverlays() {
    val base = solidFixture("z-base", 0, 180, 0) // green
    val lowZ = solidFixture("z-low", 200, 0, 0) // red  (track 1, beneath)
    val highZ = solidFixture("z-high", 0, 0, 200) // blue (track 2, on top)
    val out = File(ctx.cacheDir, "multi-track-z.mp4").absolutePath
    File(out).delete()

    val total = frameCount / fps.toDouble()
    val baseSpec = spec(base, out, outWidth = width, outHeight = height)
    // Both overlays full-duration at the same centred 0.4x0.4 rect (centre
    // 0.7,0.7). Passed ascending-z (low then high) as runCompositePip expects.
    fun layer(src: String) = TransformerRunner.OverlayLayer(
      spec = spec(src, out, outWidth = width, outHeight = height),
      frameX = 0.5, frameY = 0.5, frameW = 0.4, frameH = 0.4,
      outputStartSec = 0.0, effDurSec = total,
    )
    TransformerRunner.runCompositePip(
      ctx, listOf(baseSpec), listOf(layer(lowZ), layer(highZ)),
      totalDurationSec = total,
      compositionOverlays = emptyList(), stopToken = null, progress = null,
    )
    assertTrue("z-order output exists", File(out).exists())

    fun isBlue(c: Int) = Color.blue(c) > Color.red(c) + 40 && Color.blue(c) > Color.green(c) + 40
    fun isGreen(c: Int) = Color.green(c) > Color.red(c) + 40 && Color.green(c) > Color.blue(c) + 40

    val inBox = pixelAt(out, 0.7, 0.7, 0.5)
    val outside = pixelAt(out, 0.05, 0.05, 0.5)
    assertTrue(
      "higher-z overlay (blue) is on top in the box (got ${Integer.toHexString(inBox)})",
      isBlue(inBox),
    )
    assertTrue(
      "base (green) shows outside the overlays (got ${Integer.toHexString(outside)})",
      isGreen(outside),
    )
  }

  // Timeline-overlap crossfade (#43 — Android parity with iOS #18). A solid-red
  // clip [0, 1.0s] and a solid-blue clip starting at 0.6s overlap over [0.6, 1.0].
  // Asserts: before the overlap the frame is red, after it is blue, and at the
  // overlap midpoint both channels are present (a dissolve, not a hard cut).
  // Mirrors the iOS testMultiClipOverlapCrossfade.
  @Test
  fun crossfadeOverlapBlendsAdjacentClips() {
    val red = solidFixture("xf-a", 220, 0, 0)
    val blue = solidFixture("xf-b", 0, 0, 220)
    val out = File(ctx.cacheDir, "crossfade.mp4").absolutePath
    File(out).delete()

    val clipDur = frameCount / fps.toDouble() // 1.0s each
    val overlapStart = 0.6
    val total = overlapStart + clipDur // second clip ends here (1.6s)
    val clips = listOf(
      TransformerRunner.CrossfadeClip(
        spec = spec(red, out, outWidth = width, outHeight = height),
        outputStartSec = 0.0, effDurSec = clipDur,
      ),
      TransformerRunner.CrossfadeClip(
        spec = spec(blue, out, outWidth = width, outHeight = height),
        outputStartSec = overlapStart, effDurSec = clipDur,
      ),
    )
    TransformerRunner.runCompositeCrossfade(
      ctx, clips, totalDurationSec = total,
      compositionOverlays = emptyList(), stopToken = null, progress = null,
    )
    assertTrue("crossfade output exists", File(out).exists())
    assertEquals(total, durationSec(out), 0.3)

    fun isRed(c: Int) = Color.red(c) > Color.blue(c) + 40 && Color.red(c) > Color.green(c) + 40
    fun isBlue(c: Int) = Color.blue(c) > Color.red(c) + 40 && Color.blue(c) > Color.green(c) + 40

    // Before the overlap: pure red. After: pure blue.
    val before = pixelAt(out, 0.5, 0.5, 0.3)
    val after = pixelAt(out, 0.5, 0.5, 1.3)
    assertTrue("pre-overlap is red (got ${Integer.toHexString(before)})", isRed(before))
    assertTrue("post-overlap is blue (got ${Integer.toHexString(after)})", isBlue(after))

    // Overlap midpoint (t=0.8, p=0.5): a dissolve — both red and blue present and
    // neither washed out. Green stays low (neither source has green).
    val mid = pixelAt(out, 0.5, 0.5, 0.8)
    assertTrue(
      "overlap midpoint blends red+blue (got ${Integer.toHexString(mid)})",
      Color.red(mid) > 50 && Color.blue(mid) > 50 &&
        Color.red(mid) < 200 && Color.blue(mid) < 200,
    )
  }

  // Three-clip crossfade exercises BOTH ping-pong parities: overlap (A,B) has the
  // outgoing clip on sequence 0 (ramp 1→0); overlap (B,C) has the INCOMING clip
  // on sequence 0 (ramp 0→1). Both must still dissolve correctly. A=red[0,1.0],
  // B=green[0.6,1.6], C=blue[1.2,2.2].
  @Test
  fun crossfadeThreeClipsBlendsBothParities() {
    val red = solidFixture("xf3-a", 220, 0, 0)
    val green = solidFixture("xf3-b", 0, 200, 0)
    val blue = solidFixture("xf3-c", 0, 0, 220)
    val out = File(ctx.cacheDir, "crossfade3.mp4").absolutePath
    File(out).delete()

    val clipDur = frameCount / fps.toDouble() // 1.0s
    fun cf(src: String, start: Double) = TransformerRunner.CrossfadeClip(
      spec = spec(src, out, outWidth = width, outHeight = height),
      outputStartSec = start, effDurSec = clipDur,
    )
    val total = 1.2 + clipDur // C ends at 2.2
    TransformerRunner.runCompositeCrossfade(
      ctx, listOf(cf(red, 0.0), cf(green, 0.6), cf(blue, 1.2)),
      totalDurationSec = total,
      compositionOverlays = emptyList(), stopToken = null, progress = null,
    )
    assertTrue("3-clip crossfade output exists", File(out).exists())

    fun red(t: Double) = Color.red(pixelAt(out, 0.5, 0.5, t))
    fun green(t: Double) = Color.green(pixelAt(out, 0.5, 0.5, t))
    fun blue(t: Double) = Color.blue(pixelAt(out, 0.5, 0.5, t))

    // Solo regions: A (0.3) red, B (1.05) green, C (2.0) blue.
    assertTrue("A solo is red", red(0.3) > 150 && green(0.3) < 90 && blue(0.3) < 90)
    assertTrue("B solo is green", green(1.05) > 130 && red(1.05) < 90 && blue(1.05) < 90)
    assertTrue("C solo is blue", blue(2.0) > 150 && red(2.0) < 90 && green(2.0) < 90)
    // Overlap (A,B) midpoint t=0.8: red+green blend (seq0 outgoing, ramp 1→0).
    assertTrue("A/B overlap blends red+green", red(0.8) > 50 && green(0.8) > 50)
    // Overlap (B,C) midpoint t=1.4: green+blue blend (seq0 INCOMING, ramp 0→1).
    assertTrue("B/C overlap blends green+blue", green(1.4) > 50 && blue(1.4) > 50)
  }

  // Passthrough audio survives the crossfade and stays on the output timeline.
  // The ping-pong second sequence leads with a video-only transparent pad before
  // its audio clip, so the composition forces a continuous audio track; without
  // that, Media3 drops/mis-times the second clip's audio. Asserts the output
  // carries an audio track and spans the full (overlap-shortened) duration.
  @Test
  fun crossfadeKeepsAlignedPassthroughAudio() {
    val a = authorAudioVideoFixture("xf-aud-a")
    val b = authorAudioVideoFixture("xf-aud-b")
    assertTrue("fixtures carry audio", trackMimes(a).any { it.startsWith("audio/") })
    val out = File(ctx.cacheDir, "crossfade-audio.mp4").absolutePath
    File(out).delete()

    val clipDur = frameCount / fps.toDouble()
    val overlapStart = 0.6
    val total = overlapStart + clipDur
    TransformerRunner.runCompositeCrossfade(
      ctx,
      listOf(
        TransformerRunner.CrossfadeClip(
          spec = spec(a, out, outWidth = width, outHeight = height),
          outputStartSec = 0.0, effDurSec = clipDur,
        ),
        TransformerRunner.CrossfadeClip(
          spec = spec(b, out, outWidth = width, outHeight = height),
          outputStartSec = overlapStart, effDurSec = clipDur,
        ),
      ),
      totalDurationSec = total,
      compositionOverlays = emptyList(), stopToken = null, progress = null,
    )
    val mimes = trackMimes(out)
    assertTrue("crossfade output keeps a video track", mimes.any { it.startsWith("video/") })
    assertTrue("crossfade output keeps an audio track", mimes.any { it.startsWith("audio/") })
    assertEquals("crossfade spans the overlap-shortened timeline", total, durationSec(out), 0.3)
  }

  /// A 40x40 opaque watermark bitmap anchored at the frame centre — a static
  /// (spec-level) overlay for the composite-path tests (#52).
  private fun centerWatermark(r: Int, g: Int, b: Int): Transcoder.ResolvedOverlay {
    val bmp = Bitmap.createBitmap(40, 40, Bitmap.Config.ARGB_8888)
      .apply { eraseColor(Color.rgb(r, g, b)) }
    return Transcoder.ResolvedOverlay(
      bitmap = bmp,
      sizeW = null, sizeH = null,
      anchorX = 0.5, anchorY = 0.5,
      opacity = 1.0, timeRange = null,
    )
  }

  // #52 (1): audio.mode = 'replace' on the PiP composite path. The base audio is
  // stripped and a separate soundtrack is muxed on a parallel sequence alongside
  // the compositor; the output keeps a video track and carries the replacement
  // audio. Mirrors the single-clip transformReplaceSwapsAudioTrack.
  @Test
  fun pipReplaceSwapsAudioTrack() {
    val base = authorAudioVideoFixture("pip-repl-base")
    val pip = solidFixture("pip-repl-over", 0, 0, 220)
    val replacement = authorAudioVideoFixture("pip-repl-audio")
    val out = File(ctx.cacheDir, "pip-replace.mp4").absolutePath
    File(out).delete()
    val total = frameCount / fps.toDouble()
    val baseSpec = spec(base, out, outWidth = width, outHeight = height, audioReplacementUri = replacement)
    val overlay = TransformerRunner.OverlayLayer(
      spec = spec(pip, out, outWidth = width, outHeight = height, durationSec = 0.4),
      frameX = 0.6, frameY = 0.6, frameW = 0.3, frameH = 0.3,
      outputStartSec = 0.3, effDurSec = 0.4,
    )
    TransformerRunner.runCompositePip(
      ctx, listOf(baseSpec), listOf(overlay),
      totalDurationSec = total,
      compositionOverlays = emptyList(), stopToken = null, progress = null,
    )
    val mimes = trackMimes(out)
    assertTrue("pip+replace keeps a video track", mimes.any { it.startsWith("video/") })
    assertTrue("pip+replace carries the replacement audio track", mimes.any { it.startsWith("audio/") })
  }

  // #52 (1): audio.mode = 'replace' on the crossfade composite path. The per-clip
  // ramped soundtracks are dropped and a single replacement is muxed on a
  // parallel sequence; the output keeps video + the replacement audio.
  @Test
  fun crossfadeReplaceSwapsAudioTrack() {
    val a = authorAudioVideoFixture("xf-repl-a")
    val b = authorAudioVideoFixture("xf-repl-b")
    val replacement = authorAudioVideoFixture("xf-repl-audio")
    val out = File(ctx.cacheDir, "crossfade-replace.mp4").absolutePath
    File(out).delete()
    val clipDur = frameCount / fps.toDouble()
    val overlapStart = 0.6
    val total = overlapStart + clipDur
    TransformerRunner.runCompositeCrossfade(
      ctx,
      listOf(
        // Only the first clip's spec is read for the replacement.
        TransformerRunner.CrossfadeClip(
          spec = spec(a, out, outWidth = width, outHeight = height, audioReplacementUri = replacement),
          outputStartSec = 0.0, effDurSec = clipDur,
        ),
        TransformerRunner.CrossfadeClip(
          spec = spec(b, out, outWidth = width, outHeight = height),
          outputStartSec = overlapStart, effDurSec = clipDur,
        ),
      ),
      totalDurationSec = total,
      compositionOverlays = emptyList(), stopToken = null, progress = null,
    )
    val mimes = trackMimes(out)
    assertTrue("crossfade+replace keeps a video track", mimes.any { it.startsWith("video/") })
    assertTrue("crossfade+replace carries the replacement audio track", mimes.any { it.startsWith("audio/") })
  }

  // #52 (2): a static (spec-level) overlay composited on TOP of the PiP output
  // via a composition-level effect. A green watermark at the frame centre must
  // win over the red base there (the blue PiP box sits bottom-right, away from
  // the centre), proving the watermark draws above the whole composited frame.
  @Test
  fun pipCompositesStaticOverlayOnTop() {
    val base = solidFixture("pip-wm-base", 220, 0, 0) // red
    val pip = solidFixture("pip-wm-over", 0, 0, 220) // blue
    val out = File(ctx.cacheDir, "pip-static-overlay.mp4").absolutePath
    File(out).delete()
    val total = frameCount / fps.toDouble()
    val baseSpec = spec(base, out, outWidth = width, outHeight = height)
    val overlay = TransformerRunner.OverlayLayer(
      spec = spec(pip, out, outWidth = width, outHeight = height, durationSec = 0.4),
      frameX = 0.6, frameY = 0.6, frameW = 0.3, frameH = 0.3,
      outputStartSec = 0.3, effDurSec = 0.4,
    )
    TransformerRunner.runCompositePip(
      ctx, listOf(baseSpec), listOf(overlay),
      totalDurationSec = total,
      compositionOverlays = listOf(centerWatermark(0, 220, 0)), // green
      stopToken = null, progress = null,
    )
    assertTrue("pip+watermark output exists", File(out).exists())
    val center = centerPixel(out)
    assertTrue(
      "centre pixel is the green watermark (composited on top) got #${Integer.toHexString(center)}",
      Color.green(center) > 120 &&
        Color.green(center) > Color.red(center) + 40 &&
        Color.green(center) > Color.blue(center) + 40,
    )
  }

  // #52 (2): a static overlay composited on TOP of the crossfade output. The
  // green watermark at the centre must win over the dissolving red/blue clips.
  @Test
  fun crossfadeCompositesStaticOverlayOnTop() {
    val a = solidFixture("xf-wm-a", 220, 0, 0) // red
    val b = solidFixture("xf-wm-b", 0, 0, 220) // blue
    val out = File(ctx.cacheDir, "crossfade-static-overlay.mp4").absolutePath
    File(out).delete()
    val clipDur = frameCount / fps.toDouble()
    val overlapStart = 0.6
    val total = overlapStart + clipDur
    TransformerRunner.runCompositeCrossfade(
      ctx,
      listOf(
        TransformerRunner.CrossfadeClip(
          spec = spec(a, out, outWidth = width, outHeight = height),
          outputStartSec = 0.0, effDurSec = clipDur,
        ),
        TransformerRunner.CrossfadeClip(
          spec = spec(b, out, outWidth = width, outHeight = height),
          outputStartSec = overlapStart, effDurSec = clipDur,
        ),
      ),
      totalDurationSec = total,
      compositionOverlays = listOf(centerWatermark(0, 220, 0)), // green
      stopToken = null, progress = null,
    )
    assertTrue("crossfade+watermark output exists", File(out).exists())
    val center = centerPixel(out)
    assertTrue(
      "centre pixel is the green watermark (composited on top) got #${Integer.toHexString(center)}",
      Color.green(center) > 120 &&
        Color.green(center) > Color.red(center) + 40 &&
        Color.green(center) > Color.blue(center) + 40,
    )
  }

  // #52 (3): a base-track OVERLAP combined with a PiP overlay track. The Hybrid
  // renderCompositePip does this in two passes (mirroring iOS): pass 1
  // crossfade-dissolves the overlapping base clips to a temp via
  // runCompositeCrossfade, pass 2 composites the overlay tracks on top of that
  // temp via runCompositePip. This test runs the same two passes and asserts the
  // dissolved base (red clip A early, blue clip B late, in a region away from the
  // PiP box) AND the green PiP box on top — i.e. both compositors compose.
  @Test
  fun pipOverCrossfadedBaseCompositesBoth() {
    val baseA = solidFixture("pipxf-base-a", 220, 0, 0) // red
    val baseB = solidFixture("pipxf-base-b", 0, 0, 220) // blue
    val temp = File(ctx.cacheDir, "pipxf-base-temp.mp4").absolutePath
    File(temp).delete()
    val clipDur = frameCount / fps.toDouble()
    val overlapStart = 0.6
    val baseTotal = overlapStart + clipDur

    // Pass 1: crossfade the overlapping base clips to the temp.
    TransformerRunner.runCompositeCrossfade(
      ctx,
      listOf(
        TransformerRunner.CrossfadeClip(
          spec = spec(baseA, temp, outWidth = width, outHeight = height),
          outputStartSec = 0.0, effDurSec = clipDur,
        ),
        TransformerRunner.CrossfadeClip(
          spec = spec(baseB, temp, outWidth = width, outHeight = height),
          outputStartSec = overlapStart, effDurSec = clipDur,
        ),
      ),
      totalDurationSec = baseTotal,
      compositionOverlays = emptyList(), stopToken = null, progress = null,
    )
    assertTrue("base crossfade temp exists", File(temp).exists())

    // Pass 2: PiP a solid GREEN overlay (bottom-right box) over the dissolved base.
    val pip = solidFixture("pipxf-over", 0, 220, 0) // green
    val out = File(ctx.cacheDir, "pipxf-out.mp4").absolutePath
    File(out).delete()
    val baseSpec = spec(temp, out, outWidth = width, outHeight = height)
    val overlay = TransformerRunner.OverlayLayer(
      spec = spec(pip, out, outWidth = width, outHeight = height),
      frameX = 0.6, frameY = 0.6, frameW = 0.3, frameH = 0.3,
      outputStartSec = 0.0, effDurSec = baseTotal,
    )
    TransformerRunner.runCompositePip(
      ctx, listOf(baseSpec), listOf(overlay),
      totalDurationSec = baseTotal,
      compositionOverlays = emptyList(), stopToken = null, progress = null,
    )
    assertTrue("pip-over-crossfade output exists", File(out).exists())

    fun isRed(c: Int) = Color.red(c) > Color.blue(c) + 40 && Color.red(c) > Color.green(c) + 40
    fun isBlue(c: Int) = Color.blue(c) > Color.red(c) + 40 && Color.blue(c) > Color.green(c) + 40
    fun isGreen(c: Int) = Color.green(c) > Color.red(c) + 40 && Color.green(c) > Color.blue(c) + 40

    // Base region away from the PiP box (top-left): clip A red early, clip B blue
    // late — proving the base dissolved across the overlap.
    val earlyBase = pixelAt(out, 0.1, 0.1, 0.2)
    val lateBase = pixelAt(out, 0.1, 0.1, 1.4)
    assertTrue("base shows clip A (red) early (got ${Integer.toHexString(earlyBase)})", isRed(earlyBase))
    assertTrue("base shows clip B (blue) late (got ${Integer.toHexString(lateBase)})", isBlue(lateBase))
    // PiP box (centre 0.75,0.75) shows the green overlay on top of the base.
    val pipBox = pixelAt(out, 0.75, 0.75, 0.8)
    assertTrue("PiP box is green on top of the base (got ${Integer.toHexString(pipBox)})", isGreen(pipBox))
  }

  // The crossfade audio envelope (VolumeRampAudioProcessor): a 1.0s constant-tone
  // PCM stream with a 0.4s tail ramp should be full-amplitude before the ramp,
  // ~half at the ramp midpoint, and ~silent at the end. Validated directly on the
  // processor (no audio decode), so the gain math is pinned independent of mixing.
  @Test
  fun volumeRampAudioProcessorAppliesTailEnvelope() {
    val sampleRate = 48000
    val total = 1.0
    val tail = 0.4
    val amp: Short = 10000
    val p = VolumeRampAudioProcessor(totalSec = total, headSec = 0.0, tailSec = tail)
    p.configure(AudioProcessor.AudioFormat(sampleRate, 1, C.ENCODING_PCM_16BIT))
    p.flush()

    val frames = (total * sampleRate).toInt()
    val input = ByteBuffer.allocate(frames * 2).order(ByteOrder.LITTLE_ENDIAN)
    repeat(frames) { input.putShort(amp) }
    input.flip()
    p.queueInput(input)
    p.queueEndOfStream()

    // Drain all output into one short array.
    val collected = ShortBufferCollector()
    while (true) {
      val chunk = p.output
      if (!chunk.hasRemaining()) break
      collected.add(chunk.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer())
      if (p.isEnded) break
    }
    val samples = collected.toArray()
    assertEquals("output frame count preserved", frames, samples.size)

    fun at(tSec: Double) = abs(samples[(tSec * sampleRate).toInt().coerceIn(0, frames - 1)].toInt())
    assertTrue("full amplitude before the tail ramp (got ${at(0.5)})", abs(at(0.5) - amp) < 400)
    assertTrue("~half amplitude at tail-ramp midpoint (got ${at(0.8)})", abs(at(0.8) - amp / 2) < 600)
    assertTrue("near-silent at the end (got ${at(0.99)})", at(0.99) < 600)
  }

  /// Accumulates short buffers drained from an AudioProcessor into one array.
  private class ShortBufferCollector {
    private val chunks = ArrayList<ShortArray>()
    fun add(sb: java.nio.ShortBuffer) {
      val a = ShortArray(sb.remaining())
      sb.get(a)
      chunks.add(a)
    }
    fun toArray(): ShortArray {
      val total = chunks.sumOf { it.size }
      val out = ShortArray(total)
      var o = 0
      for (c in chunks) { c.copyInto(out, o); o += c.size }
      return out
    }
  }

  @Test
  fun fpsDownsampleDropsFrames() {
    val src = synthFixture("fps-down")
    val srcFrames = videoFrameCount(src) // ~30 (30fps, 1.0s)
    val out = File(ctx.cacheDir, "xform-fps-15.mp4").absolutePath
    // Request 15fps on a 30fps source -> Media3 FrameDropEffect keeps ~half.
    TransformerRunner.run(ctx, spec(src, out, fps = 15.0), stopToken = null, progress = null)
    assertTrue("fps output authored", File(out).exists())
    val outFrames = videoFrameCount(out)
    assertTrue(
      "downsample drops frames (src=$srcFrames, out=$outFrames)",
      outFrames in 12..20,
    )
    // We drop frames, not time: the duration is preserved.
    assertTrue("duration ~1.0s (got ${durationSec(out)})", abs(durationSec(out) - 1.0) < 0.2)
  }

  @Test
  fun cropAndTrimWindow() {
    val src = synthFixture("crop-trim")
    val out = File(ctx.cacheDir, "xform-crop-win.mp4").absolutePath
    // Crop to 80x80 + window [0.5s, 0.5s).
    TransformerRunner.run(
      ctx,
      spec(src, out, cropW = 80.0, cropH = 80.0, startSec = 0.5, durationSec = 0.5),
      stopToken = null, progress = null,
    )
    val (w, h) = dimensions(out)
    // Media3 may align to even dimensions; allow ±2px.
    assertTrue("crop width ~80 (got $w)", abs(w - 80) <= 2)
    assertTrue("crop height ~80 (got $h)", abs(h - 80) <= 2)
    assertTrue("windowed duration ~0.5s (got ${durationSec(out)})", abs(durationSec(out) - 0.5) < 0.15)
  }

  @Test
  fun rotateAndTrimSwapsDisplayedDimensions() {
    val src = synthFixture("rot-trim")
    val out = File(ctx.cacheDir, "xform-rot.mp4").absolutePath
    // rotate 90 of 160x120 → displayed 120x160; window to 0.5s. No explicit
    // output size → Media3 derives the swapped dimensions.
    TransformerRunner.run(
      ctx,
      spec(src, out, rotate = 90, startSec = 0.0, durationSec = 0.5),
      stopToken = null, progress = null,
    )
    val (w, h) = displayedDimensions(out)
    assertTrue("rotated to portrait (displayed ${w}x$h)", h > w)
    assertTrue("windowed duration ~0.5s (got ${durationSec(out)})", abs(durationSec(out) - 0.5) < 0.15)
  }

  /// Regression for #24: a single output dimension (width XOR height) used to be
  /// silently ignored on the non-overlay path (Presentation was only added when
  /// BOTH dims were pinned), so the output stayed source-sized. It must now honor
  /// the requested axis and fall back on the other (stretch), matching iOS.
  @Test
  fun singleOutputWidthResizesAndFallsBackOnHeight() {
    val src = synthFixture("out-w-only")
    val out = File(ctx.cacheDir, "xform-out-w-only.mp4").absolutePath
    // Request width=80 only on a 160x120 source. Height falls back to source
    // (120) → displayed 80x120. Use displayedDimensions(), not dimensions():
    // the API 36 hardware AVC encoder stores this portrait frame as a coded
    // 120x80 + rotation=90 flag, so METADATA_KEY_VIDEO_WIDTH/HEIGHT report the
    // pre-rotation 120x80 (#49). Media3 may align to even dims, so allow ±2px.
    TransformerRunner.run(ctx, spec(src, out, outWidth = 80), stopToken = null, progress = null)
    val (w, h) = displayedDimensions(out)
    assertTrue("requested width honored ~80 (got $w)", abs(w - 80) <= 2)
    assertTrue("height falls back to source ~120 (got $h)", abs(h - 120) <= 2)
    assertNoLetterbox(out)
  }

  @Test
  fun singleOutputHeightResizesAndFallsBackOnWidth() {
    val src = synthFixture("out-h-only")
    val out = File(ctx.cacheDir, "xform-out-h-only.mp4").absolutePath
    // Request height=60 only on a 160x120 source. Width falls back to source
    // (160) → displayed 160x60. See the width test for why displayedDimensions().
    TransformerRunner.run(ctx, spec(src, out, outHeight = 60), stopToken = null, progress = null)
    val (w, h) = displayedDimensions(out)
    assertTrue("width falls back to source ~160 (got $w)", abs(w - 160) <= 2)
    assertTrue("requested height honored ~60 (got $h)", abs(h - 60) <= 2)
    assertNoLetterbox(out)
  }

  /// Asserts the content fills the whole displayed frame (no letterbox/pillarbox
  /// bars), confirming the LAYOUT_STRETCH_TO_FIT non-uniform scale that matches
  /// iOS. The synth fixture is a flat per-frame RGB fill, so a stretched frame is
  /// uniform edge-to-edge; a letterboxed one would have black bars on the padded
  /// axis. Sample the four edge midpoints against the centre.
  ///
  /// Frame 0 of the synth pattern is pure black (`patternForFrame(0)` → 0,0,0),
  /// so black bars would compare *equal* to a black centre and the check would be
  /// vacuous. Sample a later frame whose fill is solidly non-black, and guard by
  /// asserting the centre itself is non-black before the edge comparisons.
  private fun assertNoLetterbox(path: String) {
    val r = MediaMetadataRetriever()
    try {
      r.setDataSource(path)
      val frameIdx = 5 // patternForFrame(5) = (55, 9, 229) — solidly non-black
      val bmp = r.getFrameAtIndex(frameIdx) ?: error("no frame $frameIdx in $path")
      val w = bmp.width
      val h = bmp.height
      val center = bmp.getPixel(w / 2, h / 2)
      assertTrue(
        "sampled centre is non-black (else the bar check is vacuous), got $center",
        Color.red(center) + Color.green(center) + Color.blue(center) > 60,
      )
      // Codec YUV rounding shifts colours a few levels; compare per channel with
      // a tolerance well below the gap to pure black a bar would introduce.
      fun close(a: Int, b: Int): Boolean =
        abs(Color.red(a) - Color.red(b)) <= 12 &&
          abs(Color.green(a) - Color.green(b)) <= 12 &&
          abs(Color.blue(a) - Color.blue(b)) <= 12
      val top = bmp.getPixel(w / 2, 1)
      val bottom = bmp.getPixel(w / 2, h - 2)
      val left = bmp.getPixel(1, h / 2)
      val right = bmp.getPixel(w - 2, h / 2)
      assertTrue("top edge filled (no letterbox bar)", close(top, center))
      assertTrue("bottom edge filled (no letterbox bar)", close(bottom, center))
      assertTrue("left edge filled (no pillarbox bar)", close(left, center))
      assertTrue("right edge filled (no pillarbox bar)", close(right, center))
    } finally {
      runCatching { r.release() }
    }
  }

  @Test
  fun preservesSourceAudioTrack() {
    val src = authorAudioVideoFixture("audio")
    assertTrue("fixture has audio", trackMimes(src).any { it.startsWith("audio/") })
    val out = File(ctx.cacheDir, "xform-audio-out.mp4").absolutePath
    // A flip forces a re-encode; audio must still survive.
    TransformerRunner.run(ctx, spec(src, out, flipH = true), stopToken = null, progress = null)
    val mimes = trackMimes(out)
    assertTrue("output keeps a video track", mimes.any { it.startsWith("video/") })
    assertTrue("output keeps the audio track", mimes.any { it.startsWith("audio/") })
  }

  // Passthrough concat now splices each clip's audio onto the joined timeline
  // (previously concat was video-only — the #16 "audio dropped" limit). Mute
  // writes video only. Mirrors the iOS
  // testRemuxConcatCarriesAudioPassthroughAndMuteDrops.
  @Test
  fun concatCarriesAudioPassthroughAndMuteDrops() {
    val clipA = authorAudioVideoFixture("concat-a")
    val clipB = authorAudioVideoFixture("concat-b")
    assertTrue("fixture has audio", trackMimes(clipA).any { it.startsWith("audio/") })
    val perClip = frameCount / fps.toDouble()
    val sources = listOf(
      Remuxer.ConcatSource(clipA, 0.0, perClip, 0.0),
      Remuxer.ConcatSource(clipB, 0.0, perClip, perClip),
    )

    val keep = File(ctx.cacheDir, "concat-keep.mp4").absolutePath
    File(keep).delete()
    Remuxer.remuxConcat(sources, keep, stopToken = null, audioMode = AudioMode.PASSTHROUGH)
    val keepMimes = trackMimes(keep)
    assertTrue("concat keeps a video track", keepMimes.any { it.startsWith("video/") })
    assertTrue("passthrough concat keeps audio", keepMimes.any { it.startsWith("audio/") })

    val mute = File(ctx.cacheDir, "concat-mute.mp4").absolutePath
    File(mute).delete()
    Remuxer.remuxConcat(sources, mute, stopToken = null, audioMode = AudioMode.MUTE)
    val muteMimes = trackMimes(mute)
    assertTrue("concat keeps a video track", muteMimes.any { it.startsWith("video/") })
    assertTrue("mute concat has no audio track", muteMimes.none { it.startsWith("audio/") })
  }

  // Multi-clip transcode (#14): two clips re-encoded to a shared 80x80 output,
  // joined into one EditedMediaItemSequence. The output is the concatenation,
  // re-encoded to the target dimensions.
  @Test
  fun multiClipTranscodeConcatenatesAndReencodes() {
    val a = synthFixture("multi-a")
    val b = synthFixture("multi-b")
    val out = File(ctx.cacheDir, "multi-transcode.mp4").absolutePath
    File(out).delete()
    val specs = listOf(
      spec(a, out, outWidth = 80, outHeight = 80),
      spec(b, out, outWidth = 80, outHeight = 80),
    )
    TransformerRunner.runMulti(ctx, specs, stopToken = null, progress = null)
    assertTrue("multi-clip output exists", File(out).exists())
    val (w, h) = dimensions(out)
    assertEquals(80, w)
    assertEquals(80, h)
    val perClip = frameCount / fps.toDouble()
    assertEquals(2 * perClip, durationSec(out), 0.25)
  }

  // Timeline gap (#18): a 1s black gap between two re-encoded clips via
  // EditedMediaItemSequence.addGap. The joined timeline is ~3s. Mirrors the
  // iOS testMultiClipGapFilledWithBlack.
  @Test
  fun multiClipGapFilledWithBlack() {
    val a = synthFixture("gap-a")
    val b = synthFixture("gap-b")
    val out = File(ctx.cacheDir, "multi-gap.mp4").absolutePath
    File(out).delete()
    val perClip = frameCount / fps.toDouble()
    val specs = listOf(
      spec(a, out, outWidth = 80, outHeight = 80),
      // 1s black gap before the second clip.
      spec(b, out, outWidth = 80, outHeight = 80, leadingGapSec = 1.0),
    )
    TransformerRunner.runMulti(ctx, specs, stopToken = null, progress = null)
    assertTrue("gapped multi-clip output exists", File(out).exists())
    val (w, h) = dimensions(out)
    assertEquals(80, w)
    assertEquals(80, h)
    assertEquals(2 * perClip + 1.0, durationSec(out), 0.3)
  }

  // audio.mode = 'replace' drops the source audio and muxes a separate
  // soundtrack via a parallel Media3 audio sequence; the output keeps a video
  // track and carries an audio track. Mirrors the iOS replace tests.
  @Test
  fun transformReplaceSwapsAudioTrack() {
    val src = authorAudioVideoFixture("repl-src")
    val replacement = authorAudioVideoFixture("repl-audio")
    val out = File(ctx.cacheDir, "xform-replace-out.mp4").absolutePath
    File(out).delete()
    TransformerRunner.run(
      ctx,
      spec(src, out, flipH = true, audioReplacementUri = replacement),
      stopToken = null,
      progress = null,
    )
    val mimes = trackMimes(out)
    assertTrue("output keeps a video track", mimes.any { it.startsWith("video/") })
    assertTrue("replace output carries a (swapped) audio track", mimes.any { it.startsWith("audio/") })
  }

  // Concat replace: drop every clip's audio, mux the replacement soundtrack.
  @Test
  fun concatReplaceSwapsAudioTrack() {
    val clipA = authorAudioVideoFixture("crepl-a")
    val clipB = authorAudioVideoFixture("crepl-b")
    val replacement = authorAudioVideoFixture("crepl-audio")
    val perClip = frameCount / fps.toDouble()
    val sources = listOf(
      Remuxer.ConcatSource(clipA, 0.0, perClip, 0.0),
      Remuxer.ConcatSource(clipB, 0.0, perClip, perClip),
    )
    val out = File(ctx.cacheDir, "concat-replace.mp4").absolutePath
    File(out).delete()
    Remuxer.remuxConcat(
      sources, out, stopToken = null,
      audioMode = AudioMode.REPLACE, audioReplacementUri = replacement,
    )
    val mimes = trackMimes(out)
    assertTrue("concat keeps a video track", mimes.any { it.startsWith("video/") })
    assertTrue("replace concat carries the swapped audio track", mimes.any { it.startsWith("audio/") })
  }

  // audio.mode = 'mute' drops the audio track (setRemoveAudio on the
  // EditedMediaItem); the video track survives. Mirrors the iOS
  // testTranscodeMuteDropsAudioTrack / testRemuxTransformMuteDropsAudioTrack.
  @Test
  fun muteDropsAudioTrack() {
    val src = authorAudioVideoFixture("mute")
    assertTrue("fixture has audio", trackMimes(src).any { it.startsWith("audio/") })
    val out = File(ctx.cacheDir, "xform-mute-out.mp4").absolutePath
    // A flip forces a re-encode; with removeAudio the soundtrack is dropped.
    TransformerRunner.run(
      ctx,
      spec(src, out, flipH = true, removeAudio = true),
      stopToken = null,
      progress = null,
    )
    val mimes = trackMimes(out)
    assertTrue("output keeps a video track", mimes.any { it.startsWith("video/") })
    assertTrue(
      "muted output has no audio track",
      mimes.none { it.startsWith("audio/") },
    )
  }

  @Test
  fun overlayWithTrimWindowKeepsAudio() {
    // Regression for #12: overlay + trim in one pass used to be rejected (the
    // overlay path was the legacy GL transcoder, full-source + video-only).
    // It now runs on Media3 OverlayEffect, so it trims, overlays, and keeps
    // the audio in a single pass.
    val src = authorAudioVideoFixture("overlay-trim")
    val out = File(ctx.cacheDir, "xform-overlay-trim-out.mp4").absolutePath
    val overlayBmp = Bitmap.createBitmap(40, 40, Bitmap.Config.ARGB_8888)
      .apply { eraseColor(Color.RED) }
    val overlay = Transcoder.ResolvedOverlay(
      bitmap = overlayBmp,
      sizeW = null,
      sizeH = null,
      anchorX = 0.5,
      anchorY = 0.5,
      opacity = 1.0,
      timeRange = null,
    )
    TransformerRunner.run(
      ctx,
      spec(src, out, startSec = 0.25, durationSec = 0.5).copy(
        overlays = listOf(overlay),
        outCanvasW = width,
        outCanvasH = height,
      ),
      stopToken = null, progress = null,
    )
    assertTrue("overlay+trim output authored", File(out).exists())
    assertTrue("output keeps the audio track", trackMimes(out).any { it.startsWith("audio/") })
    assertTrue(
      "windowed duration ~0.5s (got ${durationSec(out)})",
      abs(durationSec(out) - 0.5) < 0.2,
    )
    // The opaque red overlay is anchored at the frame center (0.5, 0.5), so the
    // center pixel must be red-dominant — proving the overlay is actually
    // composited (not just that the file was produced).
    val center = centerPixel(out)
    assertTrue(
      "center pixel is red (overlay composited) got #${Integer.toHexString(center)}",
      Color.red(center) > 120 &&
        Color.red(center) > Color.green(center) &&
        Color.red(center) > Color.blue(center),
    )
  }

  @Test
  fun trimsAudioWithVideo() {
    val src = authorAudioVideoFixture("audio-trim")
    val out = File(ctx.cacheDir, "xform-audio-trim-out.mp4").absolutePath
    TransformerRunner.run(
      ctx,
      spec(src, out, flipH = true, startSec = 0.25, durationSec = 0.5),
      stopToken = null, progress = null,
    )
    assertTrue("output keeps the audio track", trackMimes(out).any { it.startsWith("audio/") })
    assertTrue("trimmed duration ~0.5s (got ${durationSec(out)})", abs(durationSec(out) - 0.5) < 0.2)
  }

  /// Two transcodes in one process — the scenario that deadlocked the
  /// hand-rolled MediaCodec pump. Media3 Transformer manages the codec
  /// lifecycle, so both must complete.
  @Test
  fun backToBackTranscodesBothComplete() {
    val src = synthFixture("b2b")
    val out1 = File(ctx.cacheDir, "xform-b2b-1.mp4").absolutePath
    val out2 = File(ctx.cacheDir, "xform-b2b-2.mp4").absolutePath
    TransformerRunner.run(ctx, spec(src, out1, cropW = 80.0, cropH = 80.0), stopToken = null, progress = null)
    TransformerRunner.run(
      ctx,
      spec(src, out2, cropW = 80.0, cropH = 80.0, startSec = 0.5, durationSec = 0.5),
      stopToken = null, progress = null,
    )
    assertTrue("first output exists", File(out1).length() > 0)
    assertTrue("second output exists", File(out2).length() > 0)
    assertTrue("second is windowed ~0.5s", abs(durationSec(out2) - 0.5) < 0.15)
  }

  /// Authors a ~1.0s mp4 with both a synthesized video track and a generated
  /// silent AAC audio track, so the audio-passthrough path has something to
  /// carry. Returns the file path.
  private fun authorAudioVideoFixture(tag: String): String {
    val videoOnly = synthFixture("av-$tag")
    val out = File(ctx.cacheDir, "av-src-$tag.mp4")
    out.delete()

    val sampleRate = 44100
    val channels = 1
    val seconds = frameCount / fps.toDouble()

    val aacFormat = MediaFormat.createAudioFormat(
      MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels,
    ).apply {
      setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
      setInteger(MediaFormat.KEY_BIT_RATE, 64_000)
      setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16 * 1024)
    }
    val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    enc.configure(aacFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
    enc.start()

    val muxer = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

    val vEx = MediaExtractor().apply { setDataSource(videoOnly) }
    val vTrack = (0 until vEx.trackCount).first {
      vEx.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/")
    }
    vEx.selectTrack(vTrack)
    val outVideoTrack = muxer.addTrack(vEx.getTrackFormat(vTrack))

    val totalPcmBytes = (sampleRate * channels * 2 * seconds).toLong()
    var pcmFed = 0L
    var inputDone = false
    var outAudioTrack = -1
    var muxerStarted = false
    val info = MediaCodec.BufferInfo()
    val frameBytes = 1024 * channels * 2
    val ptsPerFrameUs = (1_000_000.0 * 1024 / sampleRate).toLong()
    var audioPtsUs = 0L

    while (true) {
      if (!inputDone) {
        val inIdx = enc.dequeueInputBuffer(10_000)
        if (inIdx >= 0) {
          val buf = enc.getInputBuffer(inIdx)!!
          buf.clear()
          if (pcmFed >= totalPcmBytes) {
            enc.queueInputBuffer(inIdx, 0, 0, audioPtsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            inputDone = true
          } else {
            val n = minOf(frameBytes.toLong(), totalPcmBytes - pcmFed).toInt()
            buf.put(ByteArray(n))
            enc.queueInputBuffer(inIdx, 0, n, audioPtsUs, 0)
            pcmFed += n
            audioPtsUs += ptsPerFrameUs
          }
        }
      }
      val outIdx = enc.dequeueOutputBuffer(info, 10_000)
      if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
        outAudioTrack = muxer.addTrack(enc.outputFormat)
        muxer.start()
        muxerStarted = true
      } else if (outIdx >= 0) {
        if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) info.size = 0
        if (info.size > 0 && muxerStarted) {
          val encoded = enc.getOutputBuffer(outIdx)!!
          muxer.writeSampleData(outAudioTrack, encoded, info)
        }
        enc.releaseOutputBuffer(outIdx, false)
        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
      }
    }

    val vInfo = MediaCodec.BufferInfo()
    val vBuf = ByteBuffer.allocate(1 shl 20)
    while (true) {
      val size = vEx.readSampleData(vBuf, 0)
      if (size < 0) break
      vInfo.offset = 0
      vInfo.size = size
      vInfo.presentationTimeUs = vEx.sampleTime
      vInfo.flags = if ((vEx.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0)
        MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
      muxer.writeSampleData(outVideoTrack, vBuf, vInfo)
      vEx.advance()
    }

    runCatching { muxer.stop() }
    runCatching { muxer.release() }
    runCatching { enc.stop() }
    runCatching { enc.release() }
    runCatching { vEx.release() }

    assertTrue("av fixture authored", out.exists() && out.length() > 0)
    return out.absolutePath
  }
}
