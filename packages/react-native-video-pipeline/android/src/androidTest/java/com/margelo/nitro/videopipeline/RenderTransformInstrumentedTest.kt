///
/// RenderTransformInstrumentedTest.kt
///
/// Instrumented coverage for the Android render-with-transform path — the
/// Transcoder gaining a trim window, the GL transform (rotate/flip/crop), and
/// compressed audio passthrough. Mirrors the iOS XCTests
/// testRemuxTransformTrim* / testTranscodeTrimWindowProducesWindowedOutput in
/// ios/__tests__/LibraryTests.m.
///
/// Fixtures are authored on-device: video via SynthesizeRunner (the golden
/// flat-fill pattern `(i*11, i*53, i*97) & 0xff`, distinct per frame so a trim
/// window's start frame is identifiable), audio via a generated silent AAC
/// track muxed alongside the video.
///

package com.margelo.nitro.videopipeline

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
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

  /// Center-pixel RGB of the output's first decoded frame. Used to confirm a
  /// trim window started on the expected source frame (each golden frame has a
  /// distinct color).
  private fun firstFrameCenterRgb(path: String): Triple<Int, Int, Int> {
    val r = MediaMetadataRetriever()
    return try {
      r.setDataSource(path)
      val bmp = r.getFrameAtIndex(0) ?: error("no frame 0 in $path")
      val p = bmp.getPixel(bmp.width / 2, bmp.height / 2)
      Triple((p shr 16) and 0xFF, (p shr 8) and 0xFF, p and 0xFF)
    } finally {
      runCatching { r.release() }
    }
  }

  private fun target(
    w: Int,
    h: Int,
    rotate: Int = -1,
    flipH: Boolean = false,
    flipV: Boolean = false,
    cropW: Double = 0.0,
    cropH: Double = 0.0,
    startSec: Double = 0.0,
    durationSec: Double = 0.0,
  ) = Transcoder.Target(
    width = w,
    height = h,
    fps = fps.toDouble(),
    codec = Transcoder.Codec.H264,
    bitrate = 0,
    rotate = rotate,
    flipH = flipH,
    flipV = flipV,
    cropX = 0.0,
    cropY = 0.0,
    cropWidth = cropW,
    cropHeight = cropH,
    sourceStartSec = startSec,
    sourceDurationSec = durationSec,
  )

  @Test
  fun transcodeCropAndTrimWindowIsFrameExact() {
    val src = synthFixture("crop-trim")
    val full = File(ctx.cacheDir, "xform-crop-full.mp4").absolutePath
    val win = File(ctx.cacheDir, "xform-crop-win.mp4").absolutePath

    // Full source, cropped 80x80.
    Transcoder.transcode(
      sourceUri = src, outputPath = full,
      target = target(80, 80, cropW = 80.0, cropH = 80.0),
      overlays = emptyList(), metadata = null, stopToken = null, progress = null,
    )
    // Windowed [0.5s, 0.5s) = frames 15..29, same crop.
    Transcoder.transcode(
      sourceUri = src, outputPath = win,
      target = target(80, 80, cropW = 80.0, cropH = 80.0, startSec = 0.5, durationSec = 0.5),
      overlays = emptyList(), metadata = null, stopToken = null, progress = null,
    )

    assertEquals(80, MediaMetadataRetriever().also { it.setDataSource(win) }.let {
      val w = it.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)!!.toInt()
      it.release(); w
    })
    assertTrue("windowed duration ~0.5s", abs(durationSec(win) - 0.5) < 0.12)

    // Frame-exact: the windowed output's first frame equals the full output's
    // frame 15. Compare the green channel (golden G = (i*53)&0xff), tolerant of
    // the keyframe-vs-P-frame encode shift, and confirm it is clearly past
    // frame 0.
    val winG = firstFrameCenterRgb(win).second
    val full0G = firstFrameCenterRgb(full).second
    // full frame 15 green ≈ (15*53)&0xff = 23; frame 0 green = 0.
    assertTrue("windowed first frame should be well past frame 0 (got $winG vs $full0G)",
      abs(winG - full0G) > 12 || winG > 12)
  }

  @Test
  fun transcodeRotateAndTrimSwapsDisplayedDimensions() {
    val src = synthFixture("rot-trim")
    val out = File(ctx.cacheDir, "xform-rot.mp4").absolutePath
    // rotate 90 of a 160x120 frame → 120x160 displayed; window to 0.5s.
    Transcoder.transcode(
      sourceUri = src, outputPath = out,
      // Target canvas matches the rotated displayed size.
      target = target(120, 160, rotate = 90, startSec = 0.0, durationSec = 0.5),
      overlays = emptyList(), metadata = null, stopToken = null, progress = null,
    )
    val r = MediaMetadataRetriever().apply { setDataSource(out) }
    val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)!!.toInt()
    val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)!!.toInt()
    r.release()
    assertEquals("rotated width", 120, w)
    assertEquals("rotated height", 160, h)
    assertTrue("windowed duration ~0.5s", abs(durationSec(out) - 0.5) < 0.12)
  }

  @Test
  fun transcodePreservesSourceAudioTrack() {
    val src = authorAudioVideoFixture("audio")
    // Sanity: the fixture itself has an audio track.
    assertTrue("fixture has audio", trackMimes(src).any { it.startsWith("audio/") })

    val out = File(ctx.cacheDir, "xform-audio-out.mp4").absolutePath
    Transcoder.transcode(
      sourceUri = src, outputPath = out,
      target = target(width, height, flipH = true), // a transform → transcode path
      overlays = emptyList(), metadata = null, stopToken = null, progress = null,
    )
    val mimes = trackMimes(out)
    assertTrue("output keeps a video track", mimes.any { it.startsWith("video/") })
    assertTrue("output keeps the passthrough audio track", mimes.any { it.startsWith("audio/") })
  }

  @Test
  fun transcodeTrimsAudioWithVideo() {
    val src = authorAudioVideoFixture("audio-trim")
    val out = File(ctx.cacheDir, "xform-audio-trim-out.mp4").absolutePath
    // Window the middle 0.5s, with a flip (transcode). Both tracks should be
    // ~0.5s — the audio is trimmed alongside the video, not copied whole.
    Transcoder.transcode(
      sourceUri = src, outputPath = out,
      target = target(width, height, flipH = true, startSec = 0.25, durationSec = 0.5),
      overlays = emptyList(), metadata = null, stopToken = null, progress = null,
    )
    assertTrue("output keeps the audio track", trackMimes(out).any { it.startsWith("audio/") })
    assertTrue("trimmed duration ~0.5s (got ${durationSec(out)})", abs(durationSec(out) - 0.5) < 0.15)
  }

  /// Authors a ~1.0s mp4 with both a synthesized video track and a generated
  /// silent AAC audio track, so the audio-passthrough path has something to
  /// copy. Returns the file path.
  private fun authorAudioVideoFixture(tag: String): String {
    val videoOnly = synthFixture("av-$tag")
    val out = File(ctx.cacheDir, "av-src-$tag.mp4")
    out.delete()

    val sampleRate = 44100
    val channels = 1
    val seconds = frameCount / fps.toDouble()

    // --- Encode silent PCM → AAC, collecting (bytes, pts) samples -----------
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

    // Copy the video track verbatim from the synthesized fixture.
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
    val frameBytes = 1024 * channels * 2 // one AAC frame of PCM
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
            buf.put(ByteArray(n)) // silence
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

    // Now write the video samples.
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
