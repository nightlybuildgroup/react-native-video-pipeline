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
///   * codec / bitrate        → Transformer video MIME + encoder settings
///   * audio                  → kept (Transformer copies it through)
///
/// Transformer requires construction + start() + cancel() + getProgress() on a
/// thread with a Looper. The render worker (Promise.parallel) has none, so the
/// whole session is driven on the main Looper and the worker blocks on a latch.
///

@file:OptIn(UnstableApi::class)

package com.margelo.nitro.videopipeline

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Crop
import androidx.media3.effect.Presentation
import androidx.media3.effect.ScaleAndRotateTransformation
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
    val hevc: Boolean,
    val bitrate: Int?,
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

    // Crop first, in source-pixel coordinates → NDC. Crop(left, right, bottom,
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

    if (spec.outWidth != null && spec.outHeight != null) {
      effects.add(
        Presentation.createForWidthAndHeight(
          spec.outWidth, spec.outHeight, Presentation.LAYOUT_SCALE_TO_FIT
        )
      )
    }
    return effects
  }

  private fun toUri(uri: String): Uri = when {
    uri.startsWith("file://") || uri.startsWith("content://") || uri.startsWith("http") ->
      Uri.parse(uri)
    else -> Uri.fromFile(File(uri))
  }
}
