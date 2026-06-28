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
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.abs

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
  ) = TransformerRunner.Spec(
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
  )

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
