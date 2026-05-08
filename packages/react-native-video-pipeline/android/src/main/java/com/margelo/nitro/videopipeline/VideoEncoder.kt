///
/// VideoEncoder.kt
///
/// Android analogue of iOS RNVPAVMuxer + RNVPWorkletFrameBridge. Owns a
/// MediaCodec H.264 encoder configured with `createInputSurface()`, an
/// EGL14 context bound to that surface, and a MediaMuxer writing the
/// encoded chunks to an MP4 at the requested output path.
///
/// Frame submission for v0.1 is deliberately a flat RGB fill — the
/// encoder's input surface is the EGL draw target, so `glClearColor` +
/// `glClear` + `eglPresentationTimeANDROID` + `eglSwapBuffers` is all we
/// need to push one opaque frame at a given PTS. This matches the iOS
/// SynthesizeRunner's `fillTestPatternRGBA` placeholder — the actual
/// worklet pump lands later (parity with iOS T041+ comment in
/// ios/SynthesizeRunner.mm).
///
/// The encoder is driven in push mode: after every swap we drain whatever
/// the encoder emitted (format and/or data buffers). At `finish()` we
/// signal EOS and drain until `BUFFER_FLAG_END_OF_STREAM` flows back, then
/// stop + release the muxer. `abort()` releases everything without muxer
/// stop and deletes the partial file — mirrors the iOS `RNVPAVMuxer`
/// abort contract so a partial MP4 never lingers on disk.
///

package com.margelo.nitro.videopipeline

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.view.Surface
import java.io.File
import kotlin.math.roundToInt

internal class VideoEncoder private constructor(
  private val outputPath: String,
  private val codec: MediaCodec,
  private val muxer: MediaMuxer,
  private val inputSurface: Surface,
  private val eglDisplay: EGLDisplay,
  private val eglContext: EGLContext,
  private val eglSurface: EGLSurface,
  private val width: Int,
  private val height: Int,
) {
  private val bufferInfo = MediaCodec.BufferInfo()
  private var trackIndex: Int = -1
  private var muxerStarted = false
  private var released = false
  // Lazily initialised on the first writeRgbaFrame so the synthesize-fixed
  // path (writeFlatFrame only) doesn't pay for the shader / texture allocation.
  private var rgbaRenderer: GLRgbaRenderer? = null

  /// Flat fill + PTS + swap. The encoder wakes up on the next drain and
  /// emits an encoded sample keyed to the PTS we set via
  /// eglPresentationTimeANDROID.
  fun writeFlatFrame(r: Int, g: Int, b: Int, ptsNs: Long) {
    drainEncoder(endOfStream = false)
    GLES20.glClearColor(r / 255f, g / 255f, b / 255f, 1f)
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
    EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, ptsNs)
    require(EGL14.eglSwapBuffers(eglDisplay, eglSurface)) {
      "eglSwapBuffers failed (0x${Integer.toHexString(EGL14.eglGetError())})"
    }
  }

  /// Compose pump entry point: upload the buffer to a GLES texture, draw it
  /// onto the encoder's input surface, present at the given PTS. The buffer
  /// must be width*height*4 RGBA8888 bytes, top-down (matches Skia
  /// `readPixels(... ColorType.RGBA_8888)` and the iOS HybridFrameTarget
  /// writeBytes contract).
  fun writeRgbaFrame(rgba: java.nio.ByteBuffer, ptsNs: Long) {
    drainEncoder(endOfStream = false)
    val renderer = rgbaRenderer ?: GLRgbaRenderer(width, height).also {
      it.init()
      rgbaRenderer = it
    }
    renderer.draw(rgba)
    EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, ptsNs)
    require(EGL14.eglSwapBuffers(eglDisplay, eglSurface)) {
      "eglSwapBuffers failed (0x${Integer.toHexString(EGL14.eglGetError())})"
    }
  }

  /// End-of-stream path: signal EOS to the encoder, drain until the output
  /// buffers flush their EOS flag, stop the muxer, release everything.
  fun finish() {
    if (released) return
    codec.signalEndOfInputStream()
    drainEncoder(endOfStream = true)
    releaseEverything(stopMuxer = true)
  }

  /// Abort path: release without flushing the encoder / stopping the muxer,
  /// then delete the partial output file. `MediaMuxer.stop` would throw on
  /// a mid-stream shutdown anyway, so skip it.
  fun abort() {
    if (released) return
    releaseEverything(stopMuxer = false)
    File(outputPath).delete()
  }

  private fun drainEncoder(endOfStream: Boolean) {
    while (true) {
      val outputBufferId = codec.dequeueOutputBuffer(bufferInfo, DEQUEUE_TIMEOUT_US)
      if (outputBufferId == MediaCodec.INFO_TRY_AGAIN_LATER) {
        if (!endOfStream) return
        // EOS path: keep polling until the encoder has drained.
        continue
      }
      if (outputBufferId == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
        check(!muxerStarted) { "encoder emitted format change after muxer started" }
        val newFormat = codec.outputFormat
        trackIndex = muxer.addTrack(newFormat)
        muxer.start()
        muxerStarted = true
        continue
      }
      if (outputBufferId < 0) {
        // INFO_OUTPUT_BUFFERS_CHANGED (API < 21) is a no-op on 21+.
        continue
      }
      val encodedBuffer = codec.getOutputBuffer(outputBufferId)
        ?: error("getOutputBuffer($outputBufferId) returned null")
      if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
        // Codec config data is folded into the track format already — skip.
        bufferInfo.size = 0
      }
      if (bufferInfo.size != 0) {
        check(muxerStarted) { "encoder emitted data before format change" }
        encodedBuffer.position(bufferInfo.offset)
        encodedBuffer.limit(bufferInfo.offset + bufferInfo.size)
        muxer.writeSampleData(trackIndex, encodedBuffer, bufferInfo)
      }
      codec.releaseOutputBuffer(outputBufferId, false)
      if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
        check(endOfStream) { "encoder hit EOS before we asked for it" }
        return
      }
    }
  }

  private fun releaseEverything(stopMuxer: Boolean) {
    released = true
    // EGL first — the input Surface is tied to the encoder.
    try { rgbaRenderer?.release() } catch (_: Throwable) {}
    rgbaRenderer = null
    try {
      EGL14.eglMakeCurrent(
        eglDisplay,
        EGL14.EGL_NO_SURFACE,
        EGL14.EGL_NO_SURFACE,
        EGL14.EGL_NO_CONTEXT,
      )
    } catch (_: Throwable) { /* ignore */ }
    try { EGL14.eglDestroySurface(eglDisplay, eglSurface) } catch (_: Throwable) {}
    try { EGL14.eglDestroyContext(eglDisplay, eglContext) } catch (_: Throwable) {}
    try { EGL14.eglReleaseThread() } catch (_: Throwable) {}
    try { EGL14.eglTerminate(eglDisplay) } catch (_: Throwable) {}
    try { inputSurface.release() } catch (_: Throwable) {}
    try { codec.stop() } catch (_: Throwable) {}
    try { codec.release() } catch (_: Throwable) {}
    if (stopMuxer && muxerStarted) {
      try { muxer.stop() } catch (_: Throwable) {}
    }
    try { muxer.release() } catch (_: Throwable) {}
  }

  companion object {
    private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
    private const val DEQUEUE_TIMEOUT_US = 10_000L // 10ms — matches typical drain loops

    /// Allocate an encoder + EGL + muxer at `outputPath`. Deletes any
    /// pre-existing file at that path (MediaMuxer refuses to overwrite).
    fun open(outputPath: String, width: Int, height: Int, fps: Int): VideoEncoder {
      require(outputPath.isNotEmpty()) { "outputPath must not be empty" }
      require(width > 0 && height > 0) { "width/height must be > 0 (got ${width}x$height)" }
      require(fps > 0) { "fps must be > 0 (got $fps)" }
      File(outputPath).apply { if (exists()) delete() }

      val codec = MediaCodec.createEncoderByType(MIME)
      val format = MediaFormat.createVideoFormat(MIME, width, height).apply {
        setInteger(
          MediaFormat.KEY_COLOR_FORMAT,
          MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
        )
        setInteger(MediaFormat.KEY_BIT_RATE, estimateBitrate(width, height, fps))
        setInteger(MediaFormat.KEY_FRAME_RATE, fps)
        setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
      }
      codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
      val inputSurface = codec.createInputSurface()
      codec.start()

      val (eglDisplay, eglContext, eglSurface) = setupEgl(inputSurface)
      EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

      val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

      return VideoEncoder(
        outputPath = outputPath,
        codec = codec,
        muxer = muxer,
        inputSurface = inputSurface,
        eglDisplay = eglDisplay,
        eglContext = eglContext,
        eglSurface = eglSurface,
        width = width,
        height = height,
      )
    }

    /// Rough bitrate budget matching the iOS AVMuxer default (0.1 bit/pixel/frame,
    /// clamped at 2 Mbit). Keeps synthesize outputs small on test fixtures while
    /// still giving real renders enough headroom.
    private fun estimateBitrate(width: Int, height: Int, fps: Int): Int {
      val bits = (width.toLong() * height.toLong() * fps.toLong() / 10L).toInt()
      return bits.coerceAtLeast(256_000).coerceAtMost(20_000_000)
    }

    private fun setupEgl(surface: Surface): Triple<EGLDisplay, EGLContext, EGLSurface> {
      val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
      require(display !== EGL14.EGL_NO_DISPLAY) { "eglGetDisplay returned EGL_NO_DISPLAY" }
      val version = IntArray(2)
      require(EGL14.eglInitialize(display, version, 0, version, 1)) {
        "eglInitialize failed"
      }
      val configAttribs = intArrayOf(
        EGL14.EGL_RED_SIZE, 8,
        EGL14.EGL_GREEN_SIZE, 8,
        EGL14.EGL_BLUE_SIZE, 8,
        EGL14.EGL_ALPHA_SIZE, 8,
        EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
        EGLExt.EGL_RECORDABLE_ANDROID, 1,
        EGL14.EGL_NONE,
      )
      val configs = arrayOfNulls<EGLConfig>(1)
      val numConfigs = IntArray(1)
      require(
        EGL14.eglChooseConfig(display, configAttribs, 0, configs, 0, 1, numConfigs, 0)
      ) { "eglChooseConfig failed" }
      require(numConfigs[0] > 0) { "eglChooseConfig returned 0 configs" }
      val config = configs[0] ?: error("eglChooseConfig returned null config")

      val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
      val context = EGL14.eglCreateContext(
        display, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0,
      )
      require(context !== EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }

      val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
      val eglSurface = EGL14.eglCreateWindowSurface(
        display, config, surface, surfaceAttribs, 0,
      )
      require(eglSurface !== EGL14.EGL_NO_SURFACE) {
        "eglCreateWindowSurface failed (0x${Integer.toHexString(EGL14.eglGetError())})"
      }
      return Triple(display, context, eglSurface)
    }

    /// Mirrors the iOS `ComposeRunner::frameCountFor` contract so the
    /// cross-platform frame-count invariant stays byte-identical. Public
    /// so HybridVideoPipeline can reuse the same rounding.
    fun frameCountFor(fps: Double, seconds: Double): Int {
      if (fps <= 0.0 || seconds <= 0.0) return 0
      return (fps * seconds).roundToInt().coerceAtLeast(0)
    }
  }
}
