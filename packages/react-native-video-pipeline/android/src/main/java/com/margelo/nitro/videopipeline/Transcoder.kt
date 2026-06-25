///
/// Transcoder.kt
///
/// Android analogue of iOS RNVPTranscoder (ios/Transcoder.{h,mm}). DIY
/// MediaCodec decode → EGL/OpenGL compose → MediaCodec encode pipeline.
/// Deliberately bare android.media.* — no Media3 Transformer dependency
/// (same rationale as T042: keep the v0.1 footprint tight). The compose
/// stage handles rotate / flipH / flipV / crop on the source frame via
/// a vertex matrix + texcoord subrect, and composites zero or more
/// `ImageOverlay`s on top via alpha-blended textured quads.
///
/// Scope for v0.1 (T044):
///   * Video track only. Source audio is not passed through — future-work
///     TODO flagged alongside the iOS transcode audio path (T033 does
///     passthrough via a second AVAssetWriterInput; Android needs a second
///     MediaMuxer track sourced from the MediaExtractor's audio samples).
///   * Image + text overlays. Both are resolved to an ARGB bitmap up front
///     (`ResolvedOverlay`) — text via `OverlayTextRasterizer` (T045) — and
///     composited through one shared alpha-blended RGBA quad path.
///   * Any transform: rotate (0/90/180/270), flipH, flipV, crop (source-
///     pixel rect). Output dims/fps/codec/bitrate follow the target; the
///     decoded frame is re-sampled onto the target canvas.
///   * Metadata: GPS via MediaMuxer.setLocation.
///   * Progress sink coalesced at 100ms, same shape as SynthesizeRunner.
///   * StopToken polled at every decoded sample — abort budget <100ms on
///     the fixture sizes T044's smoke exercises.
///
/// The MediaCodec ↔ Surface plumbing follows the canonical Google Grafika
/// pattern: decoder emits onto a SurfaceTexture wrapped as an EGL external
/// OES texture; a shared EGL context has two windows — the decoder's
/// read side and the encoder's write side; the compose loop swaps between
/// them with `eglMakeCurrent`.
///

package com.margelo.nitro.videopipeline

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaMetadataRetriever
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.graphics.SurfaceTexture
import android.view.Surface
import java.io.File
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.roundToLong

internal object Transcoder {

  class InvalidSpecException(message: String) : IllegalArgumentException(message)
  class TranscoderException(message: String) : RuntimeException(message)
  class CancelledException : RuntimeException("VideoPipeline.render: Cancelled")

  enum class Codec { H264, HEVC }

  data class Target(
    val width: Int,
    val height: Int,
    val fps: Double,
    val codec: Codec,
    /// 0 = auto (0.1 bit/pixel/frame heuristic).
    val bitrate: Int,
    /// -1 = no explicit rotation (inherit 0 from the GL path).
    val rotate: Int,
    val flipH: Boolean,
    val flipV: Boolean,
    /// cropWidth/cropHeight <= 0 → full-source crop.
    val cropX: Double,
    val cropY: Double,
    val cropWidth: Double,
    val cropHeight: Double,
  )

  data class Result(val framesWritten: Int, val aborted: Boolean)

  /// Unified overlay currency. Image and text overlays are both flattened to
  /// an ARGB bitmap + geometry up front so the GL compose path is overlay-kind
  /// agnostic. `sizeW`/`sizeH` null → natural bitmap size (always the case for
  /// text, which has no public size field). `opacity` defaults to fully opaque
  /// (text overlays carry no opacity field). The caller owns nothing once the
  /// list is handed to `transcode` — it recycles every bitmap on exit.
  class ResolvedOverlay(
    val bitmap: Bitmap,
    val sizeW: Dim?,
    val sizeH: Dim?,
    val anchorX: Double,
    val anchorY: Double,
    val opacity: Double,
    val timeRange: TimeRange?,
  )

  /// Loads + decodes an image overlay's source into a `ResolvedOverlay`.
  /// Throws `InvalidSpecException` on a missing/undecodable image.
  fun resolveImageOverlay(overlay: ImageOverlay): ResolvedOverlay =
    ResolvedOverlay(
      bitmap = loadOverlayBitmap(overlay),
      sizeW = overlay.size.w,
      sizeH = overlay.size.h,
      anchorX = overlay.anchor.x,
      anchorY = overlay.anchor.y,
      opacity = overlay.opacity ?: 1.0,
      timeRange = overlay.timeRange,
    )

  /// Rasterizes a text overlay into a natural-size `ResolvedOverlay`.
  /// Throws `InvalidSpecException` on a malformed color string.
  fun resolveTextOverlay(overlay: TextOverlay): ResolvedOverlay =
    ResolvedOverlay(
      bitmap = OverlayTextRasterizer.rasterize(overlay),
      sizeW = null,
      sizeH = null,
      anchorX = overlay.anchor.x,
      anchorY = overlay.anchor.y,
      opacity = 1.0,
      timeRange = overlay.timeRange,
    )

  fun interface ProgressSink {
    fun report(
      framesCompleted: Int,
      nbFrames: Int?,
      elapsedMs: Double,
      estimatedRemainingMs: Double?,
    )
  }

  fun transcode(
    sourceUri: String,
    outputPath: String,
    target: Target,
    overlays: List<ResolvedOverlay>,
    metadata: MetadataSpec?,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
  ): Result {
    val sourcePath = resolveFilePath(sourceUri)
    requireSource(sourcePath)
    validateTarget(target)

    File(outputPath).apply { if (exists()) delete() }

    val sourceDurationSec = probeDurationSec(sourcePath)
    val estFrameCount = if (sourceDurationSec > 0.0 && target.fps > 0.0) {
      (sourceDurationSec * target.fps).roundToLong().toInt().coerceAtLeast(1)
    } else 0

    try {
      return runPipeline(
        sourcePath = sourcePath,
        outputPath = outputPath,
        target = target,
        overlays = overlays,
        metadata = metadata,
        stopToken = stopToken,
        progress = progress,
        estimatedFrameCount = estFrameCount,
      )
    } finally {
      overlays.forEach { runCatching { it.bitmap.recycle() } }
    }
  }

  // --- validation / IO helpers --------------------------------------------

  private fun validateTarget(target: Target) {
    if (target.width <= 0 || target.height <= 0) {
      throw InvalidSpecException(
        "transcode: target dimensions must be > 0 (got ${target.width}x${target.height})"
      )
    }
    if (target.fps <= 0.0) {
      throw InvalidSpecException("transcode: target fps must be > 0 (got ${target.fps})")
    }
    if (target.rotate != -1 && target.rotate != 0 && target.rotate != 90 &&
      target.rotate != 180 && target.rotate != 270
    ) {
      throw InvalidSpecException(
        "transcode: rotate must be one of 0/90/180/270 (got ${target.rotate})"
      )
    }
    if (target.cropWidth < 0 || target.cropHeight < 0) {
      throw InvalidSpecException(
        "transcode: crop dimensions must be >= 0 (got ${target.cropWidth}x${target.cropHeight})"
      )
    }
  }

  private fun resolveFilePath(uri: String): String {
    return when {
      uri.startsWith("file://") -> uri.substring("file://".length)
      else -> uri
    }
  }

  private fun requireSource(path: String) {
    if (!File(path).exists()) {
      throw TranscoderException("Source file not found: $path")
    }
  }

  private fun probeDurationSec(path: String): Double {
    val retriever = MediaMetadataRetriever()
    return try {
      retriever.setDataSource(path)
      val durationMs = retriever
        .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
        ?.toLongOrNull() ?: 0L
      durationMs / 1000.0
    } finally {
      runCatching { retriever.release() }
    }
  }

  private fun loadOverlayBitmap(overlay: ImageOverlay): Bitmap {
    val uri = overlay.uri
    val bytes: ByteArray = when {
      uri.startsWith("http://") || uri.startsWith("https://") ->
        URL(uri).openStream().use { it.readBytes() }
      uri.startsWith("file://") -> File(uri.substring("file://".length)).readBytes()
      else -> File(uri).readBytes()
    }
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
      ?: throw InvalidSpecException("overlay: failed to decode image at $uri")
  }

  // --- Pipeline driver ---------------------------------------------------

  private fun runPipeline(
    sourcePath: String,
    outputPath: String,
    target: Target,
    overlays: List<ResolvedOverlay>,
    metadata: MetadataSpec?,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
    estimatedFrameCount: Int,
  ): Result {
    val extractor = MediaExtractor().apply { setDataSource(sourcePath) }
    val videoTrack = selectVideoTrack(extractor)
      ?: throw TranscoderException("source has no video track")
    extractor.selectTrack(videoTrack)
    val sourceFormat = extractor.getTrackFormat(videoTrack)
    val sourceMime = sourceFormat.getString(MediaFormat.KEY_MIME)
      ?: throw TranscoderException("source video track has no mime type")

    val encoderMime = when (target.codec) {
      Codec.H264 -> MediaFormat.MIMETYPE_VIDEO_AVC
      Codec.HEVC -> MediaFormat.MIMETYPE_VIDEO_HEVC
    }
    val fpsInt = target.fps.toInt().coerceAtLeast(1)
    val encoder = MediaCodec.createEncoderByType(encoderMime)
    val encoderFormat = MediaFormat.createVideoFormat(
      encoderMime, target.width, target.height,
    ).apply {
      setInteger(
        MediaFormat.KEY_COLOR_FORMAT,
        MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
      )
      val bitrate = if (target.bitrate > 0) target.bitrate
        else estimateBitrate(target.width, target.height, fpsInt)
      setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
      setInteger(MediaFormat.KEY_FRAME_RATE, fpsInt)
      setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
    }
    encoder.configure(encoderFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
    val encoderInputSurface = encoder.createInputSurface()
    encoder.start()

    // GL setup with the encoder's input Surface as the write target.
    val gl = ComposeGL.open(
      encoderSurface = encoderInputSurface,
      targetWidth = target.width,
      targetHeight = target.height,
      overlays = overlays,
    )
    // The decoder writes into a SurfaceTexture bound to the shared EGL
    // context; the compose shader samples it as an external OES texture.
    val frameSync = FrameAvailableLatch()
    val decoderOutputTexture = SurfaceTexture(gl.decoderTextureId).apply {
      setDefaultBufferSize(
        sourceFormat.getInteger(MediaFormat.KEY_WIDTH),
        sourceFormat.getInteger(MediaFormat.KEY_HEIGHT),
      )
      setOnFrameAvailableListener { frameSync.signal() }
    }
    val decoderSurface = Surface(decoderOutputTexture)
    val decoder = MediaCodec.createDecoderByType(sourceMime)
    decoder.configure(sourceFormat, decoderSurface, null, 0)
    decoder.start()

    val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    if (metadata?.location != null) {
      muxer.setLocation(
        metadata.location.latitude.toFloat(),
        metadata.location.longitude.toFloat(),
      )
    }

    val runnerState = RunnerState(
      targetFps = target.fps,
      estimatedFrameCount = estimatedFrameCount,
      stopToken = stopToken,
      progress = progress,
    )

    return try {
      pump(
        extractor = extractor,
        decoder = decoder,
        encoder = encoder,
        muxer = muxer,
        decoderOutputTexture = decoderOutputTexture,
        frameSync = frameSync,
        gl = gl,
        overlays = overlays,
        state = runnerState,
        sourceFormat = sourceFormat,
        target = target,
      )
    } catch (t: Throwable) {
      File(outputPath).delete()
      throw t
    } finally {
      runCatching { decoder.stop() }
      runCatching { decoder.release() }
      runCatching { encoder.stop() }
      runCatching { encoder.release() }
      runCatching { decoderSurface.release() }
      runCatching { decoderOutputTexture.release() }
      runCatching { gl.release() }
      runCatching { muxer.release() }
      runCatching { extractor.release() }
    }
  }

  private fun selectVideoTrack(extractor: MediaExtractor): Int? {
    for (i in 0 until extractor.trackCount) {
      val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
      if (mime.startsWith("video/")) return i
    }
    return null
  }

  private fun estimateBitrate(width: Int, height: Int, fps: Int): Int {
    val bits = (width.toLong() * height.toLong() * fps.toLong() / 10L).toInt()
    return bits.coerceAtLeast(256_000).coerceAtMost(20_000_000)
  }

  private class RunnerState(
    val targetFps: Double,
    val estimatedFrameCount: Int,
    val stopToken: VideoPipelineStopToken?,
    val progress: ProgressSink?,
  ) {
    val startNanos: Long = System.nanoTime()
    var framesWritten: Int = 0
    var lastProgressMs: Double = 0.0
    var aborted: Boolean = false
    var muxerStarted: Boolean = false
    var outputVideoTrack: Int = -1
    val bufferInfo = MediaCodec.BufferInfo()
    val decodeBufferInfo = MediaCodec.BufferInfo()

    init {
      // Seed with a definite nbFrames so bars can size themselves before
      // the first encoded sample — matches SynthesizeRunner's initial tick.
      progress?.report(0, estimatedFrameCount.takeIf { it > 0 }, 0.0, null)
    }

    fun elapsedMs(): Double = (System.nanoTime() - startNanos) / 1_000_000.0

    fun reportProgress(force: Boolean = false) {
      val sink = progress ?: return
      val elapsed = elapsedMs()
      if (!force && elapsed - lastProgressMs < COALESCE_MS) return
      val eta = if (estimatedFrameCount > 0 && framesWritten > 0) {
        val remaining = (estimatedFrameCount - framesWritten).coerceAtLeast(0)
        elapsed / framesWritten * remaining
      } else null
      sink.report(
        framesWritten,
        estimatedFrameCount.takeIf { it > 0 },
        elapsed,
        eta,
      )
      lastProgressMs = elapsed
    }
  }

  private const val COALESCE_MS = 100.0
  private const val DEQUEUE_TIMEOUT_US = 10_000L

  // --- The pump ---------------------------------------------------------

  private fun pump(
    extractor: MediaExtractor,
    decoder: MediaCodec,
    encoder: MediaCodec,
    muxer: MediaMuxer,
    decoderOutputTexture: SurfaceTexture,
    frameSync: FrameAvailableLatch,
    gl: ComposeGL,
    overlays: List<ResolvedOverlay>,
    state: RunnerState,
    sourceFormat: MediaFormat,
    target: Target,
  ): Result {
    val sourceWidth = sourceFormat.getInteger(MediaFormat.KEY_WIDTH)
    val sourceHeight = sourceFormat.getInteger(MediaFormat.KEY_HEIGHT)
    gl.setSourceDimensions(sourceWidth, sourceHeight)
    gl.setTransform(
      rotate = if (target.rotate < 0) 0 else target.rotate,
      flipH = target.flipH,
      flipV = target.flipV,
      cropX = target.cropX,
      cropY = target.cropY,
      cropW = target.cropWidth,
      cropH = target.cropHeight,
    )

    var decoderInputDone = false
    var decoderOutputDone = false
    var encoderEosRequested = false

    while (!decoderOutputDone) {
      if (state.stopToken?.isAbortRequested() == true) {
        state.aborted = true
        runCatching { encoder.stop() }
        return Result(state.framesWritten, aborted = true)
      }

      // 1) Feed the decoder from the extractor.
      if (!decoderInputDone) {
        val inputIdx = decoder.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
        if (inputIdx >= 0) {
          val inputBuf = decoder.getInputBuffer(inputIdx)
            ?: error("decoder getInputBuffer($inputIdx) returned null")
          val size = extractor.readSampleData(inputBuf, 0)
          if (size < 0) {
            decoder.queueInputBuffer(
              inputIdx, 0, 0, 0L,
              MediaCodec.BUFFER_FLAG_END_OF_STREAM,
            )
            decoderInputDone = true
          } else {
            val pts = extractor.sampleTime
            decoder.queueInputBuffer(inputIdx, 0, size, pts, 0)
            extractor.advance()
          }
        }
      }

      // 2) Drain decoder output → compose → submit to encoder surface.
      var decoded = false
      while (!decoded) {
        val outIdx = decoder.dequeueOutputBuffer(state.decodeBufferInfo, DEQUEUE_TIMEOUT_US)
        if (outIdx == MediaCodec.INFO_TRY_AGAIN_LATER) {
          break
        }
        if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ||
          outIdx == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED
        ) {
          continue
        }
        if (outIdx < 0) continue

        val eos = (state.decodeBufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
        val hasData = state.decodeBufferInfo.size != 0 ||
          (state.decodeBufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
        val doRender = state.decodeBufferInfo.size != 0
        decoder.releaseOutputBuffer(outIdx, doRender)
        if (doRender) {
          // releaseOutputBuffer(idx, true) enqueues a buffer on the
          // SurfaceTexture's producer queue — we must wait for the
          // onFrameAvailable callback before calling updateTexImage().
          frameSync.await(timeoutMs = 2000)
          decoderOutputTexture.updateTexImage()
          gl.drawFrame(
            decoderOutputTexture = decoderOutputTexture,
            overlays = overlays,
            outputFrameIndex = state.framesWritten,
            fps = state.targetFps,
          )
          val ptsNs = (state.framesWritten / state.targetFps * 1_000_000_000.0).toLong()
          gl.present(ptsNs)

          // Drain whatever encoded so far into the muxer.
          drainEncoder(encoder, muxer, state, endOfStream = false)
          state.framesWritten++
          state.reportProgress()
          decoded = true
        }
        if (eos) {
          decoderOutputDone = true
          break
        }
        if (!hasData) break
      }

      if (decoderInputDone && decoderOutputDone && !encoderEosRequested) {
        encoder.signalEndOfInputStream()
        encoderEosRequested = true
      }
    }

    if (!encoderEosRequested) {
      encoder.signalEndOfInputStream()
      encoderEosRequested = true
    }
    drainEncoder(encoder, muxer, state, endOfStream = true)

    if (state.muxerStarted) muxer.stop()
    state.reportProgress(force = true)
    return Result(state.framesWritten, aborted = false)
  }

  private fun drainEncoder(
    encoder: MediaCodec,
    muxer: MediaMuxer,
    state: RunnerState,
    endOfStream: Boolean,
  ) {
    while (true) {
      val outIdx = encoder.dequeueOutputBuffer(state.bufferInfo, DEQUEUE_TIMEOUT_US)
      if (outIdx == MediaCodec.INFO_TRY_AGAIN_LATER) {
        if (!endOfStream) return
        continue
      }
      if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
        check(!state.muxerStarted) { "encoder emitted format change after muxer started" }
        val newFormat = encoder.outputFormat
        state.outputVideoTrack = muxer.addTrack(newFormat)
        muxer.start()
        state.muxerStarted = true
        continue
      }
      if (outIdx < 0) continue
      val encodedBuffer = encoder.getOutputBuffer(outIdx)
        ?: error("encoder getOutputBuffer($outIdx) returned null")
      if ((state.bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
        state.bufferInfo.size = 0
      }
      if (state.bufferInfo.size != 0) {
        check(state.muxerStarted) { "encoder emitted data before format change" }
        encodedBuffer.position(state.bufferInfo.offset)
        encodedBuffer.limit(state.bufferInfo.offset + state.bufferInfo.size)
        muxer.writeSampleData(state.outputVideoTrack, encodedBuffer, state.bufferInfo)
      }
      encoder.releaseOutputBuffer(outIdx, false)
      if ((state.bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
        return
      }
    }
  }

  // -------------------------------------------------------------------
  // ComposeGL: EGL + shaders + overlay compositing.
  //
  // Two shader programs:
  //   1. OES shader — samples the decoded video frame as an external
  //      texture and draws into the encoder Surface with a (rotate +
  //      flipH + flipV + crop) transform baked into the texcoords.
  //   2. RGBA shader — draws overlay bitmaps as screen-space textured
  //      quads with per-overlay alpha.
  // -------------------------------------------------------------------
  internal class ComposeGL private constructor(
    private val eglDisplay: EGLDisplay,
    private val eglContext: EGLContext,
    private val eglSurface: EGLSurface,
    private val targetWidth: Int,
    private val targetHeight: Int,
    private val overlayTextures: IntArray,
    private val overlaySizes: List<Pair<Int, Int>>,
    private val oesProgram: Int,
    private val rgbaProgram: Int,
    val decoderTextureId: Int,
    private val oesATexCoordLocation: Int,
    private val oesAPositionLocation: Int,
    private val oesUTexMatrixLocation: Int,
    private val oesUSamplerLocation: Int,
    private val rgbaAPositionLocation: Int,
    private val rgbaATexCoordLocation: Int,
    private val rgbaUAlphaLocation: Int,
    private val rgbaUSamplerLocation: Int,
  ) {
    private var sourceWidth = 0
    private var sourceHeight = 0
    private val transformMatrix = FloatArray(16).also { Matrix.setIdentityM(it, 0) }
    private val oesTexCoords = floatArrayOf(
      0f, 0f,
      1f, 0f,
      0f, 1f,
      1f, 1f,
    )

    fun setSourceDimensions(w: Int, h: Int) {
      sourceWidth = w
      sourceHeight = h
    }

    /// Bakes rotate/flip/crop into the texcoords used by the OES shader.
    /// Vertex positions fill the full encoder viewport (target size).
    fun setTransform(
      rotate: Int,
      flipH: Boolean,
      flipV: Boolean,
      cropX: Double,
      cropY: Double,
      cropW: Double,
      cropH: Double,
    ) {
      val sW = sourceWidth.coerceAtLeast(1)
      val sH = sourceHeight.coerceAtLeast(1)
      val useFullSource = cropW <= 0.0 || cropH <= 0.0
      val u0 = if (useFullSource) 0f else (cropX / sW).toFloat().coerceIn(0f, 1f)
      val v0 = if (useFullSource) 0f else (cropY / sH).toFloat().coerceIn(0f, 1f)
      val u1 = if (useFullSource) 1f else ((cropX + cropW) / sW).toFloat().coerceIn(0f, 1f)
      val v1 = if (useFullSource) 1f else ((cropY + cropH) / sH).toFloat().coerceIn(0f, 1f)
      // Base tex coords (u,v) paired with vertex order: TL, TR, BL, BR.
      var tl = floatArrayOf(u0, v0)
      var tr = floatArrayOf(u1, v0)
      var bl = floatArrayOf(u0, v1)
      var br = floatArrayOf(u1, v1)
      // Apply flips on cropped rect first.
      if (flipH) {
        val t1 = tl; tl = tr; tr = t1
        val t2 = bl; bl = br; br = t2
      }
      if (flipV) {
        val t1 = tl; tl = bl; bl = t1
        val t2 = tr; tr = br; br = t2
      }
      // Apply rotation of the mapping: rotating the output right by θ
      // is equivalent to rotating the texcoord assignment left by θ.
      val r = ((rotate % 360) + 360) % 360
      val rotated = when (r) {
        0 -> arrayOf(tl, tr, bl, br)
        90 -> arrayOf(bl, tl, br, tr)
        180 -> arrayOf(br, bl, tr, tl)
        270 -> arrayOf(tr, br, tl, bl)
        else -> arrayOf(tl, tr, bl, br)
      }
      oesTexCoords[0] = rotated[0][0]; oesTexCoords[1] = rotated[0][1]
      oesTexCoords[2] = rotated[1][0]; oesTexCoords[3] = rotated[1][1]
      oesTexCoords[4] = rotated[2][0]; oesTexCoords[5] = rotated[2][1]
      oesTexCoords[6] = rotated[3][0]; oesTexCoords[7] = rotated[3][1]
    }

    fun drawFrame(
      decoderOutputTexture: SurfaceTexture,
      overlays: List<ResolvedOverlay>,
      outputFrameIndex: Int,
      fps: Double,
    ) {
      // decoderOutputTexture.getTransformMatrix returns the corrective
      // matrix the producer expects us to apply — rotation/flip baked in
      // by the OEM decoder. Chain it after our own mapping.
      val producerMatrix = FloatArray(16)
      decoderOutputTexture.getTransformMatrix(producerMatrix)

      GLES20.glViewport(0, 0, targetWidth, targetHeight)
      GLES20.glClearColor(0f, 0f, 0f, 1f)
      GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

      // --- OES source frame ----
      GLES20.glUseProgram(oesProgram)
      GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
      GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, decoderTextureId)
      GLES20.glUniform1i(oesUSamplerLocation, 0)
      GLES20.glUniformMatrix4fv(oesUTexMatrixLocation, 1, false, producerMatrix, 0)

      val vertexCoords = floatArrayOf(
        -1f,  1f,  // TL
         1f,  1f,  // TR
        -1f, -1f,  // BL
         1f, -1f,  // BR
      )
      val vBuf = asFloatBuffer(vertexCoords)
      val tBuf = asFloatBuffer(oesTexCoords)
      GLES20.glEnableVertexAttribArray(oesAPositionLocation)
      GLES20.glVertexAttribPointer(oesAPositionLocation, 2, GLES20.GL_FLOAT, false, 0, vBuf)
      GLES20.glEnableVertexAttribArray(oesATexCoordLocation)
      GLES20.glVertexAttribPointer(oesATexCoordLocation, 2, GLES20.GL_FLOAT, false, 0, tBuf)
      GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
      GLES20.glDisableVertexAttribArray(oesAPositionLocation)
      GLES20.glDisableVertexAttribArray(oesATexCoordLocation)

      // --- Overlays ----
      if (overlays.isNotEmpty()) {
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        GLES20.glUseProgram(rgbaProgram)
        val ptsSec = outputFrameIndex / fps
        overlays.forEachIndexed { idx, overlay ->
          if (!overlayActive(overlay, ptsSec)) return@forEachIndexed
          drawRgbaOverlay(overlay, idx)
        }
        GLES20.glDisable(GLES20.GL_BLEND)
      }
    }

    private fun overlayActive(overlay: ResolvedOverlay, ptsSec: Double): Boolean {
      val tr = overlay.timeRange ?: return true
      return ptsSec + 1e-6 >= tr.startSec && ptsSec <= tr.endSec + 1e-6
    }

    private fun drawRgbaOverlay(overlay: ResolvedOverlay, overlayIndex: Int) {
      val (bmpW, bmpH) = overlaySizes[overlayIndex]
      // Resolve unit-tagged dims against the output canvas. Ratio values
      // are fractions of the corresponding canvas axis. Null dims (always the
      // case for text overlays) fall back to the natural bitmap size.
      val sizeW = overlay.sizeW?.let {
        if (it.unit == SizeUnit.RATIO) it.value * targetWidth else it.value
      } ?: 0.0
      val sizeH = overlay.sizeH?.let {
        if (it.unit == SizeUnit.RATIO) it.value * targetHeight else it.value
      } ?: 0.0
      val (outW, outH) = resolveOverlayPixelSize(sizeW, sizeH, bmpW, bmpH)
      if (outW <= 0.0 || outH <= 0.0) return
      val anchorX = overlay.anchorX
      val anchorY = overlay.anchorY
      // Anchor is a normalized point in [0,1] on the output frame. Treat
      // the point as the CENTER of the overlay (matches iOS
      // RNVPOverlayRenderer's applyLayerGeometry contract).
      val centerX = anchorX * targetWidth
      val centerY = anchorY * targetHeight
      val halfW = outW / 2.0
      val halfH = outH / 2.0
      // Convert pixel rect to NDC. Note: GL y is inverted relative to
      // image-space (origin bottom-left vs top-left).
      val x0 = ((centerX - halfW) / targetWidth * 2.0 - 1.0).toFloat()
      val x1 = ((centerX + halfW) / targetWidth * 2.0 - 1.0).toFloat()
      val y0Raw = ((centerY - halfH) / targetHeight * 2.0 - 1.0).toFloat()
      val y1Raw = ((centerY + halfH) / targetHeight * 2.0 - 1.0).toFloat()
      val y0 = -y1Raw
      val y1 = -y0Raw
      val vertices = floatArrayOf(
        x0, y1,  // TL
        x1, y1,  // TR
        x0, y0,  // BL
        x1, y0,  // BR
      )
      val tex = floatArrayOf(
        0f, 0f,
        1f, 0f,
        0f, 1f,
        1f, 1f,
      )
      GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
      GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, overlayTextures[overlayIndex])
      GLES20.glUniform1i(rgbaUSamplerLocation, 1)
      GLES20.glUniform1f(rgbaUAlphaLocation, overlay.opacity.toFloat().coerceIn(0f, 1f))

      val vBuf = asFloatBuffer(vertices)
      val tBuf = asFloatBuffer(tex)
      GLES20.glEnableVertexAttribArray(rgbaAPositionLocation)
      GLES20.glVertexAttribPointer(rgbaAPositionLocation, 2, GLES20.GL_FLOAT, false, 0, vBuf)
      GLES20.glEnableVertexAttribArray(rgbaATexCoordLocation)
      GLES20.glVertexAttribPointer(rgbaATexCoordLocation, 2, GLES20.GL_FLOAT, false, 0, tBuf)
      GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
      GLES20.glDisableVertexAttribArray(rgbaAPositionLocation)
      GLES20.glDisableVertexAttribArray(rgbaATexCoordLocation)
    }

    private fun resolveOverlayPixelSize(
      sizeW: Double, sizeH: Double, bmpW: Int, bmpH: Int,
    ): Pair<Double, Double> {
      val aspect = if (bmpH > 0) bmpW.toDouble() / bmpH else 1.0
      return when {
        sizeW > 0 && sizeH > 0 -> Pair(sizeW, sizeH)
        sizeW > 0 -> Pair(sizeW, sizeW / aspect)
        sizeH > 0 -> Pair(sizeH * aspect, sizeH)
        else -> Pair(bmpW.toDouble(), bmpH.toDouble())
      }
    }

    fun present(ptsNs: Long) {
      EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, ptsNs)
      require(EGL14.eglSwapBuffers(eglDisplay, eglSurface)) {
        "eglSwapBuffers failed (0x${Integer.toHexString(EGL14.eglGetError())})"
      }
    }

    fun release() {
      runCatching {
        EGL14.eglMakeCurrent(
          eglDisplay,
          EGL14.EGL_NO_SURFACE,
          EGL14.EGL_NO_SURFACE,
          EGL14.EGL_NO_CONTEXT,
        )
      }
      if (overlayTextures.isNotEmpty()) {
        runCatching { GLES20.glDeleteTextures(overlayTextures.size, overlayTextures, 0) }
      }
      runCatching { GLES20.glDeleteTextures(1, intArrayOf(decoderTextureId), 0) }
      runCatching { GLES20.glDeleteProgram(oesProgram) }
      runCatching { GLES20.glDeleteProgram(rgbaProgram) }
      runCatching { EGL14.eglDestroySurface(eglDisplay, eglSurface) }
      runCatching { EGL14.eglDestroyContext(eglDisplay, eglContext) }
      runCatching { EGL14.eglReleaseThread() }
      runCatching { EGL14.eglTerminate(eglDisplay) }
    }

    companion object {
      fun open(
        encoderSurface: Surface,
        targetWidth: Int,
        targetHeight: Int,
        overlays: List<ResolvedOverlay>,
      ): ComposeGL {
        val overlayBitmaps = overlays.map { it.bitmap }
        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        require(display !== EGL14.EGL_NO_DISPLAY) { "eglGetDisplay → NO_DISPLAY" }
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
        val num = IntArray(1)
        require(EGL14.eglChooseConfig(display, configAttribs, 0, configs, 0, 1, num, 0)) {
          "eglChooseConfig failed"
        }
        require(num[0] > 0) { "eglChooseConfig returned 0 configs" }
        val config = configs[0] ?: error("eglChooseConfig returned null config")

        val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
        val context = EGL14.eglCreateContext(
          display, config, EGL14.EGL_NO_CONTEXT, ctxAttribs, 0,
        )
        require(context !== EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }

        val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
        val eglSurface = EGL14.eglCreateWindowSurface(
          display, config, encoderSurface, surfaceAttribs, 0,
        )
        require(eglSurface !== EGL14.EGL_NO_SURFACE) {
          "eglCreateWindowSurface failed (0x${Integer.toHexString(EGL14.eglGetError())})"
        }
        require(EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) {
          "eglMakeCurrent failed"
        }

        // Create external OES texture for the decoder output.
        val texIds = IntArray(1)
        GLES20.glGenTextures(1, texIds, 0)
        val decoderTex = texIds[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, decoderTex)
        GLES20.glTexParameteri(
          GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
          GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
          GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
          GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
          GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
          GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
          GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
          GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
        )

        val oesProg = buildProgram(VERT_OES, FRAG_OES)
        val rgbaProg = buildProgram(VERT_RGBA, FRAG_RGBA)

        val overlayTextures = IntArray(overlayBitmaps.size)
        val overlaySizes = overlayBitmaps.map { Pair(it.width, it.height) }
        if (overlayBitmaps.isNotEmpty()) {
          GLES20.glGenTextures(overlayBitmaps.size, overlayTextures, 0)
          overlayBitmaps.forEachIndexed { i, bmp ->
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, overlayTextures[i])
            GLES20.glTexParameteri(
              GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
              GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
              GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
            )
            GLES20.glTexParameteri(
              GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
            )
            android.opengl.GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bmp, 0)
          }
        }

        return ComposeGL(
          eglDisplay = display,
          eglContext = context,
          eglSurface = eglSurface,
          targetWidth = targetWidth,
          targetHeight = targetHeight,
          overlayTextures = overlayTextures,
          overlaySizes = overlaySizes,
          oesProgram = oesProg,
          rgbaProgram = rgbaProg,
          decoderTextureId = decoderTex,
          oesAPositionLocation = GLES20.glGetAttribLocation(oesProg, "aPosition"),
          oesATexCoordLocation = GLES20.glGetAttribLocation(oesProg, "aTexCoord"),
          oesUTexMatrixLocation = GLES20.glGetUniformLocation(oesProg, "uTexMatrix"),
          oesUSamplerLocation = GLES20.glGetUniformLocation(oesProg, "sTexture"),
          rgbaAPositionLocation = GLES20.glGetAttribLocation(rgbaProg, "aPosition"),
          rgbaATexCoordLocation = GLES20.glGetAttribLocation(rgbaProg, "aTexCoord"),
          rgbaUAlphaLocation = GLES20.glGetUniformLocation(rgbaProg, "uAlpha"),
          rgbaUSamplerLocation = GLES20.glGetUniformLocation(rgbaProg, "sTexture"),
        )
      }

      private const val VERT_OES = """
        attribute vec4 aPosition;
        attribute vec2 aTexCoord;
        uniform mat4 uTexMatrix;
        varying vec2 vTexCoord;
        void main() {
          gl_Position = aPosition;
          vTexCoord = (uTexMatrix * vec4(aTexCoord, 0.0, 1.0)).xy;
        }
      """

      private const val FRAG_OES = """
        #extension GL_OES_EGL_image_external : require
        precision mediump float;
        varying vec2 vTexCoord;
        uniform samplerExternalOES sTexture;
        void main() {
          gl_FragColor = texture2D(sTexture, vTexCoord);
        }
      """

      private const val VERT_RGBA = """
        attribute vec4 aPosition;
        attribute vec2 aTexCoord;
        varying vec2 vTexCoord;
        void main() {
          gl_Position = aPosition;
          vTexCoord = aTexCoord;
        }
      """

      private const val FRAG_RGBA = """
        precision mediump float;
        varying vec2 vTexCoord;
        uniform sampler2D sTexture;
        uniform float uAlpha;
        void main() {
          vec4 c = texture2D(sTexture, vTexCoord);
          gl_FragColor = vec4(c.rgb, c.a * uAlpha);
        }
      """

      private fun buildProgram(vert: String, frag: String): Int {
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, vert)
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, frag)
        val prog = GLES20.glCreateProgram()
        require(prog != 0) { "glCreateProgram returned 0" }
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        val status = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
          val log = GLES20.glGetProgramInfoLog(prog)
          GLES20.glDeleteProgram(prog)
          error("program link failed: $log")
        }
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        return prog
      }

      private fun compileShader(type: Int, src: String): Int {
        val s = GLES20.glCreateShader(type)
        require(s != 0) { "glCreateShader returned 0" }
        GLES20.glShaderSource(s, src)
        GLES20.glCompileShader(s)
        val status = IntArray(1)
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
          val log = GLES20.glGetShaderInfoLog(s)
          GLES20.glDeleteShader(s)
          error("shader compile failed: $log")
        }
        return s
      }
    }
  }

  /// A one-shot latch that matches the onFrameAvailable callback against the
  /// compose loop's awaitNewImage step. Grafika pattern, simplified for a
  /// single-thread pump (listener runs on the Looper thread of whichever
  /// HandlerThread the SurfaceTexture was constructed on — here, the
  /// caller's thread, so the signal is a simple flag + notifyAll).
  internal class FrameAvailableLatch {
    private val lock = Object()
    private var available = false

    fun signal() {
      synchronized(lock) {
        available = true
        lock.notifyAll()
      }
    }

    fun await(timeoutMs: Long) {
      val deadline = System.nanoTime() + timeoutMs * 1_000_000L
      synchronized(lock) {
        while (!available) {
          val remaining = (deadline - System.nanoTime()) / 1_000_000L
          if (remaining <= 0L) {
            throw TranscoderException(
              "timed out waiting for decoder frame (${timeoutMs}ms)"
            )
          }
          try { lock.wait(remaining) } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            throw TranscoderException("interrupted waiting for decoder frame")
          }
        }
        available = false
      }
    }
  }

  private fun asFloatBuffer(data: FloatArray): FloatBuffer {
    val bb = ByteBuffer.allocateDirect(data.size * 4).apply { order(ByteOrder.nativeOrder()) }
    val fb = bb.asFloatBuffer()
    fb.put(data).position(0)
    return fb
  }
}
