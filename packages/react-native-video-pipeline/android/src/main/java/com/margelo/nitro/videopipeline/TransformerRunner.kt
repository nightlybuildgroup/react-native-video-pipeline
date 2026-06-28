///
/// TransformerRunner.kt
///
/// Android render-with-transform engine, built on Media3 Transformer — the
/// canonical Jetpack pipeline for trim + transform + re-encode (see
/// docs/architecture.md). Replaces the hand-rolled MediaCodec pump for the
/// `Video.render` single-clip transcode path. Transformer owns the
/// decode → effects → encode lifecycle, so there is no DIY codec/EOS plumbing
/// to deadlock across back-to-back renders; it preserves the source audio by
/// default, trims via `ClippingConfiguration`, and transmuxes (copies
/// compressed samples, no re-encode) when the requested edit needs no pixel
/// work — e.g. a rotation-only spec.
///
/// Mapping from the public `ClipTransform` / output spec to Media3:
///   * trim window           → MediaItem.ClippingConfiguration (start/end ms)
///   * crop (source-px rect)  → effect Crop (NDC rect)
///   * rotate (0/90/180/270)  → effect ScaleAndRotateTransformation (CW)
///   * flipH / flipV          → same effect, scale x/y by -1
///   * explicit output size   → effect Presentation
///   * target fps (downsample) → effect FrameDropEffect
///   * native overlays        → effect OverlayEffect (BitmapOverlay per overlay)
///   * codec / bitrate        → Transformer video MIME + encoder settings
///   * audio                  → kept (Transformer copies it through)
///
/// Frame-rate note: Media3 can only *drop* frames (FrameDropEffect), never
/// interpolate, so `fps` here is always a downsample target (≤ source) — the
/// router rejects an `output.fps` above the source rate before constructing the
/// Spec. The default frame-drop strategy approximates the target rate from the
/// real frame timestamps; it does not re-time every PTS to `outputIndex / fps`
/// the way the iOS resampler does, so the output rate is approximate.
///
/// Transformer requires construction + start() + cancel() + getProgress() on a
/// thread with a Looper. The render worker (Promise.parallel) has none, so the
/// whole session is driven on the main Looper and the worker blocks on a latch.
///

@file:OptIn(UnstableApi::class)

package com.margelo.nitro.videopipeline

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.Crop
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.OverlaySettings
import androidx.media3.effect.Presentation
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

internal object TransformerRunner {

  class TransformerException(message: String) : RuntimeException(message)
  class CancelledException : RuntimeException("VideoPipeline.render: Cancelled")

  /// Everything the render router resolves for a single-clip transcode.
  /// `outWidth`/`outHeight` are null when the caller didn't pin them (Media3
  /// then derives the output size from the effects). `rotate < 0` = none;
  /// `cropW`/`cropH <= 0` = no crop. `sourceWidth`/`sourceHeight` are the
  /// coded source dimensions, needed to map a source-pixel crop into NDC.
  data class Spec(
    val sourceUri: String,
    val outputPath: String,
    val sourceWidth: Int,
    val sourceHeight: Int,
    val startSec: Double,
    val durationSec: Double,
    val rotate: Int,
    val flipH: Boolean,
    val flipV: Boolean,
    val cropX: Double,
    val cropY: Double,
    val cropW: Double,
    val cropH: Double,
    val outWidth: Int?,
    val outHeight: Int?,
    /// Target frame rate. Null = keep the source rate. Always a downsample
    /// (≤ source) — the router rejects an `output.fps` above the source rate,
    /// since Media3 has no frame interpolation.
    val fps: Double?,
    val hevc: Boolean,
    val bitrate: Int?,
    /// Native overlays composited on top of the transformed frame via Media3
    /// OverlayEffect. The runner owns these bitmaps and recycles them on exit.
    val overlays: List<Transcoder.ResolvedOverlay> = emptyList(),
    /// The resolved output canvas size, used to convert RATIO overlay sizes and
    /// to scale each overlay bitmap to its target pixel size. Only read when
    /// `overlays` is non-empty.
    val outCanvasW: Int = 0,
    val outCanvasH: Int = 0,
  )

  fun interface ProgressSink {
    fun report(progressPercent: Int)
  }

  fun run(
    context: Context,
    spec: Spec,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
  ) {
    try {
      runInternal(context, spec, stopToken, progress)
    } finally {
      // Media3 uploads each overlay bitmap to a GL texture during export; once
      // run() returns (success, error, or cancel) the textures are released and
      // the source bitmaps are no longer needed.
      spec.overlays.forEach { runCatching { it.bitmap.recycle() } }
    }
  }

  private fun runInternal(
    context: Context,
    spec: Spec,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
  ) {
    File(spec.outputPath).apply { if (exists()) delete() }

    val editedItem = EditedMediaItem.Builder(buildMediaItem(spec))
      .setEffects(Effects(emptyList(), buildVideoEffects(spec)))
      .build()

    val mainHandler = Handler(Looper.getMainLooper())
    val latch = CountDownLatch(1)
    val exportError = AtomicReference<ExportException?>(null)
    val cancelled = AtomicBoolean(false)
    val transformerRef = AtomicReference<Transformer?>(null)

    mainHandler.post {
      val builder = Transformer.Builder(context)
      if (spec.hevc) builder.setVideoMimeType(MimeTypes.VIDEO_H265)
      if (spec.bitrate != null && spec.bitrate > 0) {
        builder.setEncoderFactory(
          DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(
              VideoEncoderSettings.Builder().setBitrate(spec.bitrate).build()
            )
            .build()
        )
      }
      val transformer = builder
        .addListener(object : Transformer.Listener {
          override fun onCompleted(composition: Composition, result: ExportResult) {
            latch.countDown()
          }

          override fun onError(
            composition: Composition,
            result: ExportResult,
            exception: ExportException,
          ) {
            exportError.set(exception)
            latch.countDown()
          }
        })
        .build()
      transformerRef.set(transformer)
      transformer.start(editedItem, spec.outputPath)
    }

    // Cancellation + progress are polled on the main Looper (the only thread
    // allowed to touch the Transformer instance).
    val progressHolder = ProgressHolder()
    val poll = object : Runnable {
      override fun run() {
        val transformer = transformerRef.get()
        if (transformer == null) {
          mainHandler.postDelayed(this, 50)
          return
        }
        if (stopToken?.isAbortRequested() == true && cancelled.compareAndSet(false, true)) {
          runCatching { transformer.cancel() }
          latch.countDown()
          return
        }
        if (progress != null &&
          transformer.getProgress(progressHolder) == Transformer.PROGRESS_STATE_AVAILABLE
        ) {
          progress.report(progressHolder.progress)
        }
        mainHandler.postDelayed(this, 100)
      }
    }
    mainHandler.post(poll)

    latch.await()
    mainHandler.removeCallbacks(poll)

    if (cancelled.get()) {
      File(spec.outputPath).delete()
      throw CancelledException()
    }
    val err = exportError.get()
    if (err != null) {
      File(spec.outputPath).delete()
      throw TransformerException(
        err.message ?: "Media3 export failed (errorCode=${err.errorCode})"
      )
    }
  }

  private fun buildMediaItem(spec: Spec): MediaItem {
    val builder = MediaItem.Builder().setUri(toUri(spec.sourceUri))
    val hasWindow = spec.startSec > 1e-3 || spec.durationSec > 0.0
    if (hasWindow) {
      val clip = MediaItem.ClippingConfiguration.Builder()
        .setStartPositionMs((spec.startSec * 1000.0).toLong().coerceAtLeast(0))
      if (spec.durationSec > 0.0) {
        clip.setEndPositionMs(((spec.startSec + spec.durationSec) * 1000.0).toLong())
      }
      builder.setClippingConfiguration(clip.build())
    }
    return builder.build()
  }

  private fun buildVideoEffects(spec: Spec): List<Effect> {
    val effects = ArrayList<Effect>()

    // Frame-rate downsample first, so the rest of the chain only processes the
    // frames that survive. Media3's default frame-drop strategy keeps frames
    // whose timestamps fall closest to the target interval; it never adds
    // frames, which is why the router rejects fps > source upstream.
    if (spec.fps != null && spec.fps > 0.0) {
      effects.add(FrameDropEffect.createDefaultFrameDropEffect(spec.fps.toFloat()))
    }

    // Crop next, in source-pixel coordinates → NDC. Crop(left, right, bottom,
    // top) with axes in [-1, 1]; NDC y is bottom-up while a source crop rect is
    // top-down, so the top edge maps to the larger NDC y.
    if (spec.cropW > 0.0 && spec.cropH > 0.0) {
      val sw = spec.sourceWidth.coerceAtLeast(1).toDouble()
      val sh = spec.sourceHeight.coerceAtLeast(1).toDouble()
      val left = (spec.cropX / sw * 2.0 - 1.0).toFloat()
      val right = ((spec.cropX + spec.cropW) / sw * 2.0 - 1.0).toFloat()
      val top = (1.0 - spec.cropY / sh * 2.0).toFloat()
      val bottom = (1.0 - (spec.cropY + spec.cropH) / sh * 2.0).toFloat()
      effects.add(Crop(left, right, bottom, top))
    }

    val hasRotate = spec.rotate == 90 || spec.rotate == 180 || spec.rotate == 270
    if (hasRotate || spec.flipH || spec.flipV) {
      effects.add(
        ScaleAndRotateTransformation.Builder()
          .setScale(if (spec.flipH) -1f else 1f, if (spec.flipV) -1f else 1f)
          // ClipTransform.rotate is clockwise (matches the iOS contract);
          // Media3 rotates counter-clockwise for positive degrees, so negate.
          .setRotationDegrees(if (hasRotate) (360 - spec.rotate).toFloat() else 0f)
          .build()
      )
    }

    // Pin the output canvas via Presentation whenever the output size is
    // constrained: both dimensions pinned, a *single* dimension pinned (the
    // fallback fills the other axis from content size, swapped for a quarter-turn
    // rotation), or overlays present (anchored to the output frame). The router
    // resolves `outCanvasW`/`outCanvasH` to `output.width ?: fallbackW` and
    // `output.height ?: fallbackH`, mirroring iOS makeTranscodeTarget, so a
    // single requested dimension produces a concrete output here too instead of
    // being silently dropped. Skipped when nothing constrains the size (no dims,
    // no overlays — e.g. flip/rotate-only), preserving the transmux fast path:
    // a single dimension already forces a re-encode, so there is none to lose.
    val pinCanvas = spec.outWidth != null || spec.outHeight != null || spec.overlays.isNotEmpty()
    if (pinCanvas && spec.outCanvasW > 0 && spec.outCanvasH > 0) {
      effects.add(
        Presentation.createForWidthAndHeight(
          spec.outCanvasW, spec.outCanvasH, Presentation.LAYOUT_SCALE_TO_FIT
        )
      )
    }

    // Overlays composite last, on top of the transformed + resized frame, so
    // their anchor/size are relative to the final output canvas (matching the
    // legacy GL compose path and the iOS overlay renderer).
    if (spec.overlays.isNotEmpty()) {
      val canvasW = spec.outCanvasW.coerceAtLeast(1)
      val canvasH = spec.outCanvasH.coerceAtLeast(1)
      val textureOverlays = spec.overlays.map { buildOverlay(it, canvasW, canvasH) }
      effects.add(OverlayEffect(ArrayList<TextureOverlay>(textureOverlays)))
    }
    return effects
  }

  /// Maps one resolved overlay to a Media3 [TextureOverlay]. The GL compose path
  /// treats the overlay's `anchor` as the *center* of the overlay placed at a
  /// normalised point on the output frame (image-space, y-down); Media3 uses NDC
  /// (y-up, origin center). The overlay is rendered at its bitmap's native pixel
  /// size by default, so a target pixel size becomes a `scale` of out/native.
  private fun buildOverlay(
    overlay: Transcoder.ResolvedOverlay,
    canvasW: Int,
    canvasH: Int,
  ): TextureOverlay {
    val bmpW = overlay.bitmap.width.coerceAtLeast(1)
    val bmpH = overlay.bitmap.height.coerceAtLeast(1)

    // Resolve unit-tagged sizes to output pixels (RATIO → fraction of canvas),
    // then aspect-fill against the natural bitmap size, mirroring the GL path.
    val sizeWpx = overlay.sizeW?.let {
      if (it.unit == SizeUnit.RATIO) it.value * canvasW else it.value
    } ?: 0.0
    val sizeHpx = overlay.sizeH?.let {
      if (it.unit == SizeUnit.RATIO) it.value * canvasH else it.value
    } ?: 0.0
    val aspect = bmpW.toDouble() / bmpH.toDouble()
    val (outW, outH) = when {
      sizeWpx > 0 && sizeHpx > 0 -> Pair(sizeWpx, sizeHpx)
      sizeWpx > 0 -> Pair(sizeWpx, sizeWpx / aspect)
      sizeHpx > 0 -> Pair(sizeHpx * aspect, sizeHpx)
      else -> Pair(bmpW.toDouble(), bmpH.toDouble())
    }

    // anchor (image-space, y-down, overlay center) → background NDC (y-up).
    val bgX = (overlay.anchorX * 2.0 - 1.0).toFloat()
    val bgY = (1.0 - overlay.anchorY * 2.0).toFloat()
    val scaleX = (outW / bmpW).toFloat()
    val scaleY = (outH / bmpH).toFloat()
    val alpha = overlay.opacity.toFloat().coerceIn(0f, 1f)

    val activeSettings = OverlaySettings.Builder()
      .setBackgroundFrameAnchor(bgX, bgY)
      .setScale(scaleX, scaleY)
      .setAlphaScale(alpha)
      .build()

    val tr = overlay.timeRange
    if (tr == null) {
      return BitmapOverlay.createStaticBitmapOverlay(overlay.bitmap, activeSettings)
    }
    // Time-ranged overlay: invisible (alpha 0) outside [startSec, endSec]. The
    // presentation timestamps after clipping start at 0, matching the output
    // timeline the public timeRange is expressed against.
    val startUs = (tr.startSec * 1_000_000.0).toLong() - 1_000
    val endUs = (tr.endSec * 1_000_000.0).toLong() + 1_000
    val hiddenSettings = OverlaySettings.Builder().setAlphaScale(0f).build()
    return object : BitmapOverlay() {
      override fun getBitmap(presentationTimeUs: Long): Bitmap = overlay.bitmap
      override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings =
        if (presentationTimeUs in startUs..endUs) activeSettings else hiddenSettings
    }
  }

  private fun toUri(uri: String): Uri = when {
    uri.startsWith("file://") || uri.startsWith("content://") || uri.startsWith("http") ->
      Uri.parse(uri)
    else -> Uri.fromFile(File(uri))
  }
}
