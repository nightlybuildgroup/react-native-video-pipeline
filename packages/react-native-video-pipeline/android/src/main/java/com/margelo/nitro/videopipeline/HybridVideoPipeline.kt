///
/// HybridVideoPipeline.kt
///
/// Android Nitro adapter. Routes every Nitro method to its platform
/// runner:
///
///   - `render()` — routes synthesize (null-input, T041) and multi-clip
///     compressed-passthrough concat (T042). Single-clip + any transform /
///     overlay / re-encode lands on the transcode path in T044.
///   - `trim()` — T042. Compressed passthrough via Remuxer.remuxTrim.
///   - `flip()` — rejects in v0.1; the true horizontal/vertical flip is a
///     matrix operation in the MP4 `tkhd` that MediaMuxer's API doesn't
///     expose (only `setOrientationHint(0|90|180|270)`). T044's transcode
///     path supplies the real flip.
///   - `stamp()` — T042 metadata-only branch via Remuxer.remuxStamp.
///     Watermark branch rejects until T044 wires the Android transcode +
///     BitmapOverlay.
///   - `info()`, `thumbnail()`, `capabilities()` — T043. Implemented via
///     ProbeRunner (MediaExtractor + MediaMetadataRetriever + MediaCodecList).
///
/// Error message prefixes match iOS:
///   - "VideoPipeline.render: Cancelled" → CancelledError in src/video.ts.
///   - "VideoPipeline.render: InvalidSpec — …" for JS-mirror validation.
///   - "VideoPipeline.<method>: not implemented yet on Android" for stubs.
///

package com.margelo.nitro.videopipeline

import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.core.Promise
import kotlin.math.roundToInt

class VideoPipelineNotImplementedException(method: String) :
  RuntimeException("VideoPipeline.$method: not implemented yet on Android")

class VideoPipelineCancelledException :
  RuntimeException("VideoPipeline.render: Cancelled")

class VideoPipelineInvalidSpecException(detail: String) :
  RuntimeException("VideoPipeline.render: InvalidSpec — $detail")

@DoNotStrip
@Keep
class HybridVideoPipeline : HybridVideoPipelineSpec() {

  init {
    // First render-adjacent moment after launch (the HybridObject is
    // constructed once, lazily, on first JS access): clean up any render that
    // a prior process left in-flight when it was killed (T047 / US8).
    com.margelo.nitro.NitroModules.applicationContext?.applicationContext?.let {
      RenderJournal.drainZombiesOnce(it)
    }
  }

  private fun <T> rejectedNotImplemented(method: String): Promise<T> =
    Promise.rejected(VideoPipelineNotImplementedException(method))

  override fun info(uri: String): Promise<VideoInfo> = Promise.parallel {
    try {
      ProbeRunner.info(uri)
    } catch (e: ProbeRunner.NotFoundException) {
      throw RuntimeException("VideoPipeline.info failed: ${e.message}")
    } catch (e: ProbeRunner.InvalidSpecException) {
      throw VideoPipelineInvalidSpecException("info: ${e.message}")
    }
  }

  override fun thumbnail(uri: String, options: ThumbnailOptions): Promise<String> =
    Promise.parallel {
      val resizeW = options.resizeTo?.w ?: 0.0
      val resizeH = options.resizeTo?.h ?: 0.0
      try {
        ProbeRunner.thumbnail(
          uri = uri,
          atSec = options.atSec,
          outPath = options.outPath,
          resizeW = resizeW,
          resizeH = resizeH,
        )
      } catch (e: ProbeRunner.NotFoundException) {
        throw RuntimeException("VideoPipeline.thumbnail failed: ${e.message}")
      } catch (e: ProbeRunner.InvalidSpecException) {
        throw VideoPipelineInvalidSpecException("thumbnail: ${e.message}")
      }
    }

  override fun capabilities(): Promise<EncoderCaps> = Promise.parallel {
    ProbeRunner.capabilities()
  }

  override fun render(
    spec: VideoSpec,
    renderToken: String,
    onProgress: ((p: Progress) -> Unit)?,
  ): Promise<Unit> {
    val clips = spec.clips
    return if (clips == null || clips.isEmpty()) {
      renderSynthesize(spec, renderToken, onProgress)
    } else {
      renderClips(spec, clips.toList(), renderToken)
    }
  }

  override fun cancelRender(renderToken: String) {
    RenderTokenRegistry.lookup(renderToken)?.requestAbort()
  }

  override fun finishRender(renderToken: String) {
    RenderTokenRegistry.lookup(renderToken)?.requestFinish()
  }

  /**
   * Compose pump — Android. Two branches:
   *   1. Synthesize (no clips): for each frame, hand JS a HybridFrameTarget,
   *      block on the returned Promise, upload the bytes to the encoder's
   *      input surface, repeat. Mirrors the iOS renderCompose linear loop.
   *   2. Compose-on-clip (one clip): not yet implemented on Android — needs
   *      AHardwareBuffer-backed FrameSource so Skia.Image.MakeImageFromNativeBuffer
   *      can read decoded source frames. Tracked separately.
   */
  override fun renderCompose(
    spec: VideoSpec,
    renderToken: String,
    drawFrame: (
      target: HybridFrameTargetSpec,
      source: HybridFrameSourceSpec?,
      frameIndex: Double,
      timeSec: Double,
    ) -> Promise<Boolean>,
    onProgress: ((p: Progress) -> Unit)?,
  ): Promise<Unit> {
    val isSynthesized = spec.clips.isNullOrEmpty()
    if (!isSynthesized) {
      val clip = spec.clips!!.first()
      val outputPath = spec.output.path
      val stopToken = RenderTokenRegistry.registerToken(renderToken)
      val guard = RenderForegroundGuard.begin(renderToken, outputPath, keepAlive = true)
      val progressSink: SynthesizeRunner.ProgressSink? =
        onProgress?.let { cb -> wrapProgressCallback(cb) }
      return Promise.parallel {
        try {
          composeOnClip(
            clipUri = clip.uri,
            outputPath = outputPath,
            drawFrame = drawFrame,
            stopToken = stopToken,
            progress = progressSink,
          )
          // Patch the freshly-written MP4 with caller-supplied custom
          // metadata items. MediaMuxer doesn't expose an API for arbitrary
          // moov.udta items, so we do it ourselves after finalize. iOS
          // achieves the same via AVAssetWriter.metadata.
          spec.metadata?.custom?.let { custom ->
            if (custom.isNotEmpty()) {
              Mp4MetadataInjector.inject(outputPath, custom)
            }
          }
        } finally {
          guard.end()
          RenderTokenRegistry.unregisterToken(renderToken)
        }
      }
    }

    val rejection = describeSynthesizeRejection(spec)
    if (rejection != null) {
      return Promise.rejected(VideoPipelineInvalidSpecException(rejection))
    }

    val output = spec.output
    val widthPx = output.width!!.roundToInt()
    val heightPx = output.height!!.roundToInt()
    val fps = output.fps!!
    val outputPath = output.path
    val durationVariant = spec.duration!!
    val seconds = if (durationVariant is Variant_FixedDuration_OpenDuration.First) {
      durationVariant.value.seconds
    } else {
      return Promise.rejected(
        VideoPipelineInvalidSpecException(
          "VideoPipeline.renderCompose: only fixed-duration synthesize is " +
            "supported in this slice on Android."
        )
      )
    }

    val frameCount = VideoEncoder.frameCountFor(fps, seconds)
    if (frameCount <= 0) {
      return Promise.rejected(
        VideoPipelineInvalidSpecException(
          "VideoPipeline.renderCompose: computed frame count is 0 for " +
            "fps=$fps, seconds=$seconds"
        )
      )
    }

    val stopToken = RenderTokenRegistry.registerToken(renderToken)
    val guard = RenderForegroundGuard.begin(renderToken, outputPath, keepAlive = true)
    val progressSink: SynthesizeRunner.ProgressSink? =
      onProgress?.let { cb -> wrapProgressCallback(cb) }

    return Promise.parallel {
      try {
        composeSynthesize(
          width = widthPx,
          height = heightPx,
          fps = fps,
          frameCount = frameCount,
          outputPath = outputPath,
          drawFrame = drawFrame,
          stopToken = stopToken,
          progress = progressSink,
        )
        spec.metadata?.custom?.let { custom ->
          if (custom.isNotEmpty()) {
            Mp4MetadataInjector.inject(outputPath, custom)
          }
        }
      } finally {
        guard.end()
        RenderTokenRegistry.unregisterToken(renderToken)
      }
    }
  }

  private fun composeSynthesize(
    width: Int,
    height: Int,
    fps: Double,
    frameCount: Int,
    outputPath: String,
    drawFrame: (
      target: HybridFrameTargetSpec,
      source: HybridFrameSourceSpec?,
      frameIndex: Double,
      timeSec: Double,
    ) -> Promise<Boolean>,
    stopToken: VideoPipelineStopToken?,
    progress: SynthesizeRunner.ProgressSink?,
  ) {
    java.io.File(outputPath).apply { if (exists()) delete() }
    val fpsInt = fps.coerceAtLeast(1.0).toInt().coerceAtLeast(1)
    val encoder = VideoEncoder.open(outputPath, width, height, fpsInt)
    val startNanos = System.nanoTime()
    progress?.report(
      0, frameCount, 0.0, (frameCount.toDouble() / fps) * 1000.0,
    )

    // One persistent backing buffer reused per frame — the ByteBuffer is
    // wrapped in a fresh HybridFrameTarget each iteration so JS can't
    // accidentally retain it across frames (invalidate() guards).
    val buffer = java.nio.ByteBuffer
      .allocateDirect(width * height * 4)
      .order(java.nio.ByteOrder.nativeOrder())

    var lastProgressMs = 0.0
    try {
      var i = 0
      while (i < frameCount) {
        if (stopToken?.isAbortRequested() == true) {
          encoder.abort()
          progress?.report(i, frameCount, elapsedMsSince(startNanos), 0.0)
          throw VideoPipelineCancelledException()
        }
        val target = HybridFrameTarget(
          backing = buffer,
          widthPx = width,
          heightPx = height,
          pixelFormat = PixelFormat.RGBA8888,
        )
        val timeSec = i.toDouble() / fps
        try {
          // The JS callback returns a Nitro Promise<Boolean>; await() is a
          // suspend function. We're on a worker thread (Promise.parallel),
          // so runBlocking is safe — it doesn't block any RN-managed queue.
          kotlinx.coroutines.runBlocking {
            drawFrame(target, null, i.toDouble(), timeSec).await()
          }
        } catch (t: Throwable) {
          target.invalidate()
          encoder.abort()
          throw t
        }
        target.invalidate()

        val ptsNs = (timeSec * 1_000_000_000.0).toLong()
        encoder.writeRgbaFrame(target.pixelsForEncoder(), ptsNs)

        val framesCompleted = i + 1
        val elapsedMs = elapsedMsSince(startNanos)
        if (
          progress != null &&
          (framesCompleted == frameCount || elapsedMs - lastProgressMs >= COALESCE_MS)
        ) {
          val remaining = (frameCount - framesCompleted).coerceAtLeast(0)
          val etaMs = if (framesCompleted > 0) {
            elapsedMs / framesCompleted * remaining
          } else 0.0
          progress.report(framesCompleted, frameCount, elapsedMs, etaMs)
          lastProgressMs = elapsedMs
        }
        if (framesCompleted % 50 == 0 || framesCompleted == frameCount) {
          android.util.Log.d(
            "RNVP.renderCompose",
            "$framesCompleted/$frameCount frames in ${elapsedMs.toLong()}ms " +
              "(${elapsedMs / framesCompleted}ms/frame)",
          )
        }
        i++
      }
      encoder.finish()
    } catch (t: Throwable) {
      encoder.abort()
      throw t
    }
  }

  /**
   * Compose-on-clip pump. Pulls decoded frames from `clipUri` via
   * `MediaExtractor` + `MediaCodec`, renders each onto an off-screen FBO via
   * a samplerExternalOES shader, copies the RGBA bytes into a ByteBuffer
   * wrapped as a `HybridFrameSource`, hands it to JS alongside a fresh
   * `HybridFrameTarget`, and pushes the JS draw result into the encoder.
   *
   * Output dimensions / FPS / PTS all follow the source — the spec.output
   * width/height/fps fields are ignored if present (matches iOS behavior).
   */
  private fun composeOnClip(
    clipUri: String,
    outputPath: String,
    drawFrame: (
      target: HybridFrameTargetSpec,
      source: HybridFrameSourceSpec?,
      frameIndex: Double,
      timeSec: Double,
    ) -> Promise<Boolean>,
    stopToken: VideoPipelineStopToken?,
    progress: SynthesizeRunner.ProgressSink?,
  ) {
    require(android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
      "composeOnClip: AHardwareBuffer-backed source path requires Android API 26+ " +
        "(this device is API ${android.os.Build.VERSION.SDK_INT})"
    }
    java.io.File(outputPath).apply { if (exists()) delete() }
    val encoder: VideoEncoder
    val decoder: ClipDecoder
    val targetBuffer: java.nio.ByteBuffer

    // Pre-parse the source format so we can size the encoder; the decoder
    // (ImageReader-backed) needs no GL context, so order doesn't matter.
    val tempExtractor = android.media.MediaExtractor()
    val path = if (clipUri.startsWith("file://")) clipUri.removePrefix("file://") else clipUri
    tempExtractor.setDataSource(path)
    var w = 0; var h = 0; var fps = 30
    for (i in 0 until tempExtractor.trackCount) {
      val f = tempExtractor.getTrackFormat(i)
      if (f.getString(android.media.MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
        w = f.getInteger(android.media.MediaFormat.KEY_WIDTH)
        h = f.getInteger(android.media.MediaFormat.KEY_HEIGHT)
        if (f.containsKey(android.media.MediaFormat.KEY_FRAME_RATE)) {
          fps = f.getInteger(android.media.MediaFormat.KEY_FRAME_RATE)
        }
        break
      }
    }
    tempExtractor.release()
    require(w > 0 && h > 0) { "composeOnClip: invalid source dims ${w}x$h" }

    encoder = VideoEncoder.open(outputPath, w, h, fps)
    decoder = ClipDecoder.open(clipUri)

    targetBuffer = java.nio.ByteBuffer
      .allocateDirect(decoder.width * decoder.height * 4)
      .order(java.nio.ByteOrder.nativeOrder())

    val startNanos = System.nanoTime()
    val ptsHolder = LongArray(1)
    var lastProgressMs = 0.0
    var frameIndex = 0
    val nbFrames = decoder.nbFrames
    var totalDecodeMs = 0L
    var totalJsMs = 0L
    var totalEncodeMs = 0L

    try {
      while (true) {
        if (stopToken?.isAbortRequested() == true) {
          encoder.abort()
          throw VideoPipelineCancelledException()
        }
        val tDecode = System.nanoTime()
        val image = decoder.awaitNextFrame(ptsHolder) ?: break
        // The Java HardwareBuffer carries its own ref on the underlying
        // AHardwareBuffer; closing the Image releases the ImageReader slot
        // back to the pool while Skia (and we) still hold the buffer alive.
        val hwb = image.hardwareBuffer
          ?: error("composeOnClip: ImageReader returned image with null hardwareBuffer")
        image.close()
        totalDecodeMs += (System.nanoTime() - tDecode) / 1_000_000L

        val hwbPtr = AHardwareBufferBridge.nativePtr(hwb)
        require(hwbPtr != 0L) {
          "composeOnClip: AHardwareBufferBridge returned null pointer"
        }

        val source = HybridFrameSource(
          hardwareBufferPtr = hwbPtr,
          widthPx = decoder.width,
          heightPx = decoder.height,
          pixelFormat = PixelFormat.RGBA8888,
        )
        val target = HybridFrameTarget(
          backing = targetBuffer,
          widthPx = decoder.width,
          heightPx = decoder.height,
          pixelFormat = PixelFormat.RGBA8888,
        )
        val timeSec = ptsHolder[0] / 1_000_000.0
        val tJs = System.nanoTime()
        try {
          kotlinx.coroutines.runBlocking {
            drawFrame(target, source, frameIndex.toDouble(), timeSec).await()
          }
        } catch (t: Throwable) {
          source.invalidate()
          target.invalidate()
          try { hwb.close() } catch (_: Throwable) {}
          encoder.abort()
          throw t
        }
        source.invalidate()
        target.invalidate()
        // Drop our HardwareBuffer ref now that Skia has disposed its SkImage
        // (drawWithSkia disposes sourceImage in its finally before returning).
        try { hwb.close() } catch (_: Throwable) {}
        totalJsMs += (System.nanoTime() - tJs) / 1_000_000L

        val tEncode = System.nanoTime()
        encoder.writeRgbaFrame(target.pixelsForEncoder(), ptsHolder[0] * 1_000L)
        totalEncodeMs += (System.nanoTime() - tEncode) / 1_000_000L
        frameIndex++

        val elapsedMs = elapsedMsSince(startNanos)
        if (
          progress != null &&
          (frameIndex == nbFrames || elapsedMs - lastProgressMs >= COALESCE_MS)
        ) {
          val remaining = (nbFrames - frameIndex).coerceAtLeast(0)
          val etaMs = if (frameIndex > 0) elapsedMs / frameIndex * remaining else 0.0
          progress.report(frameIndex, nbFrames, elapsedMs, etaMs)
          lastProgressMs = elapsedMs
        }
        if (frameIndex % 50 == 0) {
          android.util.Log.d(
            "RNVP.renderCompose",
            "$frameIndex/$nbFrames frames in ${elapsedMs.toLong()}ms " +
              "(${elapsedMs / frameIndex}ms/frame) [compose-on-clip] " +
              "decode=${totalDecodeMs / frameIndex}ms " +
              "js=${totalJsMs / frameIndex}ms " +
              "encode=${totalEncodeMs / frameIndex}ms",
          )
        }
      }
      encoder.finish()
      android.util.Log.d(
        "RNVP.renderCompose",
        "$frameIndex frames in ${elapsedMsSince(startNanos).toLong()}ms " +
          "(compose-on-clip done)",
      )
    } catch (t: Throwable) {
      encoder.abort()
      throw t
    } finally {
      try { decoder.close() } catch (_: Throwable) {}
    }
  }

  private fun elapsedMsSince(startNanos: Long): Double {
    return (System.nanoTime() - startNanos) / 1_000_000.0
  }

  private companion object {
    private const val COALESCE_MS = 100.0
  }

  override fun trim(
    uri: String,
    outPath: String,
    startSec: Double,
    durationSec: Double,
    renderToken: String,
    onProgress: ((p: Progress) -> Unit)?,
  ): Promise<Unit> {
    // `trim` is the lossless-cut primitive: pure passthrough remux, no
    // transform. Trimming *and* transforming in one pass goes through
    // `render`, whose router picks remux (rotation-only) vs transcode
    // (flip/crop). Remux trim has no decode/encode loop to instrument, so
    // `onProgress` is accepted for API uniformity and ignored. See
    // `docs/api.md`.
    // Passthrough remux finishes in milliseconds — journal-only (no
    // foreground-service notification flicker), but still cleaned up on a
    // mid-op kill via the journal.
    val guard = RenderForegroundGuard.begin(renderToken, outPath, keepAlive = false)
    return Promise.parallel {
      try {
        Remuxer.remuxTrim(
          sourceUri = uri,
          outputPath = outPath,
          startSec = startSec,
          durationSec = durationSec,
        )
        Unit
      } finally {
        guard.end()
      }
    }
  }

  override fun flip(
    uri: String,
    outPath: String,
    axis: FlipAxis,
    renderToken: String,
    onProgress: ((p: Progress) -> Unit)?,
  ): Promise<Unit> = Promise.rejected(
    VideoPipelineInvalidSpecException(
      "flip: Android v0.1 does not support rotation-flag flip — MediaMuxer " +
        "only exposes orientation hint (0/90/180/270), not the matrix " +
        "operation needed for horizontal/vertical flip. Transcode fallback " +
        "lands in T044."
    )
  )

  override fun stamp(
    uri: String,
    outPath: String,
    watermark: Variant_ImageOverlay_TextOverlay?,
    metadata: MetadataSpec?,
    renderToken: String,
    onProgress: ((p: Progress) -> Unit)?,
  ): Promise<Unit> {
    if (watermark == null && metadata == null) {
      return Promise.rejected(
        VideoPipelineInvalidSpecException(
          "stamp: at least one of watermark or metadata must be provided"
        )
      )
    }
    // Metadata-only stamp stays on the remux path — no re-encode needed.
    // Journal-only (fast), same rationale as trim.
    if (watermark == null) {
      val guard = RenderForegroundGuard.begin(renderToken, outPath, keepAlive = false)
      return Promise.parallel {
        try {
          Remuxer.remuxStamp(sourceUri = uri, outputPath = outPath, metadata = metadata!!)
          Unit
        } finally {
          guard.end()
        }
      }
    }
    val stopToken = RenderTokenRegistry.registerToken(renderToken)
    val guard = RenderForegroundGuard.begin(renderToken, outPath, keepAlive = true)
    return Promise.parallel {
      try {
        // Image overlays decode a source bitmap; text overlays (T045)
        // rasterize natively via OverlayTextRasterizer. Both flatten to a
        // ResolvedOverlay the GL compose path treats identically. Resolved
        // inside the worker so file IO / rasterization stay off the JS thread.
        val resolved = when (watermark) {
          is Variant_ImageOverlay_TextOverlay.First ->
            Transcoder.resolveImageOverlay(watermark.value)
          is Variant_ImageOverlay_TextOverlay.Second ->
            Transcoder.resolveTextOverlay(watermark.value)
        }
        // Probe the source for dimensions + fps — stamp inherits them, the
        // watermark just composites on top of decoded frames re-encoded at
        // the same shape.
        val info = ProbeRunner.info(uri)
        val target = Transcoder.Target(
          width = info.width.roundToInt(),
          height = info.height.roundToInt(),
          fps = if (info.fps > 0.0) info.fps else 30.0,
          codec = Transcoder.Codec.H264,
          bitrate = 0, // auto (0.1 bit/pixel/frame heuristic in Transcoder)
          rotate = -1,
          flipH = false,
          flipV = false,
          cropX = 0.0,
          cropY = 0.0,
          cropWidth = 0.0,
          cropHeight = 0.0,
        )
        val progressSink: Transcoder.ProgressSink? = onProgress?.let { cb ->
          Transcoder.ProgressSink { framesCompleted, nbFrames, elapsedMs, etaMs ->
            cb(
              Progress(
                framesCompleted = framesCompleted.toDouble(),
                nbFrames = nbFrames?.toDouble(),
                elapsedMs = elapsedMs,
                estimatedRemainingMs = etaMs,
              )
            )
          }
        }
        val result = Transcoder.transcode(
          sourceUri = uri,
          outputPath = outPath,
          target = target,
          overlays = listOf(resolved),
          metadata = metadata,
          stopToken = stopToken,
          progress = progressSink,
        )
        if (result.aborted) throw VideoPipelineCancelledException()
        Unit
      } catch (e: Transcoder.CancelledException) {
        throw VideoPipelineCancelledException()
      } catch (e: Transcoder.InvalidSpecException) {
        throw VideoPipelineInvalidSpecException(e.message ?: "transcode rejected")
      } finally {
        guard.end()
        RenderTokenRegistry.unregisterToken(renderToken)
      }
    }
  }

  // --- renderers ------------------------------------------------------

  private fun renderSynthesize(
    spec: VideoSpec,
    renderToken: String,
    onProgress: ((p: Progress) -> Unit)?,
  ): Promise<Unit> {
    val rejection = describeSynthesizeRejection(spec)
    if (rejection != null) {
      return Promise.rejected(VideoPipelineInvalidSpecException(rejection))
    }

    val output = spec.output
    val width = output.width!!.roundToInt()
    val height = output.height!!.roundToInt()
    val fps = output.fps!!
    val outputPath = output.path
    val durationVariant = spec.duration!!

    val stopToken = RenderTokenRegistry.registerToken(renderToken)
    val guard = RenderForegroundGuard.begin(renderToken, outputPath, keepAlive = true)
    val progressSink: SynthesizeRunner.ProgressSink? =
      onProgress?.let { cb -> wrapProgressCallback(cb) }

    return Promise.parallel {
      try {
        if (durationVariant is Variant_FixedDuration_OpenDuration.First) {
          val seconds = durationVariant.value.seconds
          val result = SynthesizeRunner.runFixed(
            outputPath = outputPath,
            width = width,
            height = height,
            fps = fps,
            seconds = seconds,
            stopToken = stopToken,
            progress = progressSink,
          )
          if (result.aborted) throw VideoPipelineCancelledException()
        } else {
          val open = (durationVariant as Variant_FixedDuration_OpenDuration.Second).value
          val maxSeconds = open.maxSeconds ?: 0.0
          val result = SynthesizeRunner.runOpen(
            outputPath = outputPath,
            width = width,
            height = height,
            fps = fps,
            maxSeconds = maxSeconds,
            stopToken = stopToken,
            progress = progressSink,
          )
          if (result.aborted) throw VideoPipelineCancelledException()
        }
        Unit
      } finally {
        guard.end()
        RenderTokenRegistry.unregisterToken(renderToken)
      }
    }
  }

  private fun renderClips(
    spec: VideoSpec,
    clips: List<Clip>,
    renderToken: String,
  ): Promise<Unit> {
    val rejection = describeConcatBranchRejection(spec, clips)
    if (rejection != null) {
      return Promise.rejected(VideoPipelineInvalidSpecException(rejection))
    }

    val sources = clips.map {
      Remuxer.ConcatSource(
        uri = it.uri,
        sourceStart = it.sourceStart,
        sourceDuration = it.sourceDuration,
        outputStart = it.outputStart,
      )
    }
    val outputPath = spec.output.path
    val stopToken = RenderTokenRegistry.registerToken(renderToken)
    val guard = RenderForegroundGuard.begin(renderToken, outputPath, keepAlive = true)

    return Promise.parallel {
      try {
        Remuxer.remuxConcat(
          sources = sources,
          outputPath = outputPath,
          stopToken = stopToken,
        )
        Unit
      } catch (e: Remuxer.CancelledException) {
        throw VideoPipelineCancelledException()
      } finally {
        guard.end()
        RenderTokenRegistry.unregisterToken(renderToken)
      }
    }
  }

  // --- helpers --------------------------------------------------------

  private fun wrapProgressCallback(
    cb: (Progress) -> Unit,
  ): SynthesizeRunner.ProgressSink =
    SynthesizeRunner.ProgressSink { framesCompleted, nbFrames, elapsedMs, etaMs ->
      cb(
        Progress(
          framesCompleted = framesCompleted.toDouble(),
          nbFrames = nbFrames?.toDouble(),
          elapsedMs = elapsedMs,
          estimatedRemainingMs = etaMs,
        )
      )
    }

  /// JS validates every render spec in src/video.ts before calling native;
  /// this mirror guards direct-C++ callers and future instrumentation that
  /// bypasses JS. Shape-for-shape copy of iOS describeSynthesizeRejection
  /// in ios/VideoPipeline.mm — any change must land on both sides.
  private fun describeSynthesizeRejection(spec: VideoSpec): String? {
    val duration = spec.duration ?: return "synthesize requires a duration"
    when (duration) {
      is Variant_FixedDuration_OpenDuration.First -> {
        if (duration.value.seconds <= 0.0) return "duration.seconds must be > 0"
      }
      is Variant_FixedDuration_OpenDuration.Second -> {
        val max = duration.value.maxSeconds
        if (max != null && max <= 0.0) {
          return "duration.maxSeconds must be > 0 when provided"
        }
      }
    }
    val output = spec.output
    if (output.width == null || output.width <= 0.0) {
      return "output.width is required and must be > 0"
    }
    if (output.height == null || output.height <= 0.0) {
      return "output.height is required and must be > 0"
    }
    if (output.fps == null || output.fps <= 0.0) {
      return "output.fps is required and must be > 0"
    }
    if (output.path.isEmpty()) {
      return "output.path must not be empty"
    }
    return null
  }

  /// Android v0.1 concat is passthrough-only. Any of these force the
  /// transcode path, which isn't wired yet:
  ///   - duration (concat infers duration from clips, not a spec field)
  ///   - overlays (render-path overlays require encode)
  ///   - a non-empty ClipTransform (rotate/flip/crop all need a GPU pass)
  ///   - output-side changes (width/height/fps/codec/bitrate)
  private fun describeConcatBranchRejection(
    spec: VideoSpec,
    clips: List<Clip>,
  ): String? {
    if (spec.duration != null) {
      return "duration is only valid when clips is empty"
    }
    val overlays = spec.overlays
    if (overlays != null && overlays.isNotEmpty()) {
      return "overlays on a multi-clip spec require the transcode path (T044)"
    }
    clips.forEachIndexed { i, clip ->
      val t = clip.transform
      if (t != null && clipTransformIsNonEmpty(t)) {
        return "clip[$i].transform requires the transcode path (T044)"
      }
    }
    val output = spec.output
    if (output.width != null || output.height != null || output.fps != null ||
      output.codec != null || output.bitrate != null
    ) {
      return "output-side re-encode (width/height/fps/codec/bitrate) requires " +
        "the transcode path (T044)"
    }
    return null
  }

  private fun clipTransformIsNonEmpty(t: ClipTransform): Boolean =
    t.rotate != null || (t.flipH ?: false) || (t.flipV ?: false) || t.crop != null
}
