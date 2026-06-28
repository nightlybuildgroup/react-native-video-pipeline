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
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.Crop
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.OverlaySettings
import androidx.media3.effect.Presentation
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.effect.TextureOverlay
import androidx.media3.effect.VideoCompositorSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
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
import kotlin.math.roundToInt
import kotlin.math.roundToLong

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
    /// The resolved output canvas size — `output.width ?: fallbackW`,
    /// `output.height ?: fallbackH` (fallback = crop rect or source, swapped for
    /// a quarter-turn rotation). Read when overlays are present (to convert RATIO
    /// overlay sizes and scale each bitmap to its target pixel size) and to pin
    /// the `Presentation` when a single output dimension is requested.
    val outCanvasW: Int = 0,
    val outCanvasH: Int = 0,
    /// Audio handling (spec.audio). `false` (default) keeps the source audio,
    /// which Media3 Transformer copies through. `true` drops the audio track
    /// (audio.mode = 'mute'). When `audioReplacementUri` is set
    /// (audio.mode = 'replace') the source audio is dropped and the soundtrack
    /// from that URI is muxed in via a parallel audio sequence.
    val removeAudio: Boolean = false,
    val audioReplacementUri: String? = null,
    /// Output video duration in seconds, used to clip the replacement
    /// soundtrack (Media3 sequence ordering does not bound the export, so a
    /// longer replacement would otherwise extend it with an audio-only tail).
    val outputDurationSec: Double? = null,
    /// Black + silent gap (seconds) inserted BEFORE this clip's item on the
    /// multi-clip sequence (#18). 0 = no gap (contiguous).
    val leadingGapSec: Double = 0.0,
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

  /// Multi-clip transcode (#14): each clip becomes an [EditedMediaItem] carrying
  /// its own crop/rotate/flip/trim plus the shared output presentation / fps /
  /// overlays, joined into one [EditedMediaItemSequence] that Media3 concatenates
  /// and re-encodes to the shared output. Audio: passthrough lets Media3
  /// concatenate each clip's audio; mute drops it per item; replace muxes a
  /// parallel audio sequence from `audioReplacementUri` (capped to the total
  /// duration). Every entry in `clipSpecs` shares the same output fields
  /// (hevc / bitrate / overlays / audio); the first is read for the
  /// composition-level settings.
  fun runMulti(
    context: Context,
    clipSpecs: List<Spec>,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
  ) {
    require(clipSpecs.isNotEmpty()) { "runMulti requires at least one clip" }
    try {
      runMultiInternal(context, clipSpecs, stopToken, progress)
    } finally {
      // Overlays are the shared spec-level set (the same references appear on
      // every clip spec); recycle each distinct bitmap once.
      clipSpecs.flatMap { it.overlays }.toHashSet().forEach { runCatching { it.bitmap.recycle() } }
    }
  }

  /// Author a black PNG at the shared canvas size, used as the video source for
  /// timeline-gap fills (#18). Returned file lives in the cache dir; the caller
  /// deletes it.
  private fun authorBlackImage(context: Context, w: Int, h: Int): File {
    val bmp = Bitmap.createBitmap(w.coerceAtLeast(2), h.coerceAtLeast(2), Bitmap.Config.ARGB_8888)
      .apply { eraseColor(Color.BLACK) }
    val file = File.createTempFile("rnvp-gap-black", ".png", context.cacheDir)
    java.io.FileOutputStream(file).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
    bmp.recycle()
    return file
  }

  /// Author a fully-transparent PNG at the shared canvas size, used to pad an
  /// overlay / ping-pong sequence so it spans the whole output duration while
  /// contributing nothing (alpha 0) outside its own window — the layer beneath
  /// shows through (#43/#45). Media3's `addGap()` is an audio-raw gap and emits
  /// no video, so a transparent image item is used instead (mirrors the
  /// black-image gap-fill in [authorBlackImage]).
  private fun authorTransparentImage(context: Context, w: Int, h: Int): File {
    val bmp = Bitmap.createBitmap(w.coerceAtLeast(2), h.coerceAtLeast(2), Bitmap.Config.ARGB_8888)
      .apply { eraseColor(Color.TRANSPARENT) }
    val file = File.createTempFile("rnvp-pad-transparent", ".png", context.cacheDir)
    java.io.FileOutputStream(file).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
    bmp.recycle()
    return file
  }

  /// One overlay/PiP track to composite on top of the base timeline (#17/#45).
  /// `spec` is the overlay clip's own trim/transform, presented to the shared
  /// canvas; `frame*` is its normalized destination rect (top-left origin, 0..1);
  /// `outputStartSec`/`effDurSec` place its window on the output timeline.
  data class OverlayLayer(
    val spec: Spec,
    val frameX: Double,
    val frameY: Double,
    val frameW: Double,
    val frameH: Double,
    val outputStartSec: Double,
    val effDurSec: Double,
  )

  /// Multi-track / PiP compositing (#45 — Android parity with iOS #17). Builds a
  /// Media3 [Composition] with one [EditedMediaItemSequence] per layer:
  ///
  ///   * the base timeline (`baseSpecs`, the track-0 clips — single or multi-clip
  ///     with gaps, built exactly like [runMulti]) as the BACK layer, and
  ///   * one sequence per overlay track, each padded with transparent images
  ///     before/after its window so every sequence spans the full output
  ///     duration.
  ///
  /// Media3's [androidx.media3.effect.DefaultVideoCompositor] draws the FIRST
  /// registered sequence on top and later ones beneath (reverse registration
  /// order). To match the iOS z-order (base at the back, higher track index more
  /// on top) the sequences are registered topmost-overlay-first, then descending,
  /// with the base LAST. A [VideoCompositorSettings] scales + anchors each overlay
  /// input into its `frame` rect; the base input is left full-frame.
  ///
  /// Overlay audio is dropped in v1 (mirrors iOS); the base audio follows
  /// `baseSpecs.first()` (passthrough / mute / replace).
  fun runCompositePip(
    context: Context,
    baseSpecs: List<Spec>,
    overlays: List<OverlayLayer>,
    totalDurationSec: Double,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
  ) {
    require(baseSpecs.isNotEmpty()) { "runCompositePip requires a base track" }
    require(overlays.isNotEmpty()) { "runCompositePip requires at least one overlay" }
    try {
      runCompositePipInternal(context, baseSpecs, overlays, totalDurationSec, stopToken, progress)
    } finally {
      val all = baseSpecs.flatMap { it.overlays } + overlays.flatMap { it.spec.overlays }
      all.toHashSet().forEach { runCatching { it.bitmap.recycle() } }
    }
  }

  private fun runCompositePipInternal(
    context: Context,
    baseSpecs: List<Spec>,
    overlays: List<OverlayLayer>,
    totalDurationSec: Double,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
  ) {
    val first = baseSpecs.first()
    val canvasW = first.outCanvasW.coerceAtLeast(2)
    val canvasH = first.outCanvasH.coerceAtLeast(2)
    File(first.outputPath).apply { if (exists()) delete() }

    val needBaseGaps = baseSpecs.any { it.leadingGapSec > 1e-3 }
    val blackImage: File? =
      if (needBaseGaps) authorBlackImage(context, canvasW, canvasH) else null
    val transparent = authorTransparentImage(context, canvasW, canvasH)
    try {
      // Base layer (back) — the track-0 clips, joined exactly like runMulti.
      val baseSeq = buildClipSequence(baseSpecs, blackImage)

      // Overlay layers, each padded to the full output duration so the
      // Composition is not truncated to a single overlay's window.
      val overlaySeqs = overlays.map { layer ->
        val b = EditedMediaItemSequence.Builder()
        val lead = layer.outputStartSec
        val trail = totalDurationSec - layer.outputStartSec - layer.effDurSec
        val padFps = (layer.spec.fps?.roundToInt() ?: 30).coerceAtLeast(1)
        if (lead > 1e-3) b.addItem(transparentItem(transparent, lead, padFps))
        b.addItem(
          EditedMediaItem.Builder(buildMediaItem(layer.spec))
            .setEffects(Effects(emptyList(), buildVideoEffects(layer.spec)))
            // Overlay audio is dropped in v1 (mirrors iOS multi-track).
            .setRemoveAudio(true)
            .build()
        )
        if (trail > 1e-3) b.addItem(transparentItem(transparent, trail, padFps))
        b.build()
      }

      // Registration order: topmost overlay first (drawn on top), then descending
      // z, then the base last (drawn at the back). `overlays` is ascending z.
      val orderedOverlays = overlays.reversed()
      val orderedSeqs = overlaySeqs.reversed().toMutableList().apply { add(baseSeq) }
      val baseInputId = orderedSeqs.size - 1

      val compositor = object : VideoCompositorSettings {
        override fun getOutputSize(inputSizes: MutableList<Size>): Size = Size(canvasW, canvasH)

        override fun getOverlaySettings(inputId: Int, presentationTimeUs: Long): OverlaySettings {
          if (inputId == baseInputId) return OverlaySettings.Builder().build()
          val layer = orderedOverlays[inputId]
          return pipOverlaySettings(layer)
        }
      }

      val composition = Composition.Builder(orderedSeqs)
        .setVideoCompositorSettings(compositor)
        .build()

      runTransformer(context, first.outputPath, first.hevc, first.bitrate, stopToken, progress) { transformer ->
        transformer.start(composition, first.outputPath)
      }
    } finally {
      blackImage?.delete()
      transparent.delete()
    }
  }

  /// A transparent-pad image item of the given duration, used to position an
  /// overlay clip on its sequence's timeline (see [authorTransparentImage]).
  private fun transparentItem(image: File, durationSec: Double, fps: Int): EditedMediaItem =
    EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(image)))
      .setDurationUs((durationSec * 1_000_000.0).roundToLong())
      .setFrameRate(fps.coerceAtLeast(1))
      .build()

  /// OverlaySettings that scale a full-canvas overlay input into its normalized
  /// `frame` rect and anchor its center at the rect center. `setScale(w, h)`
  /// shrinks the (canvas-sized) overlay to `w*canvasW × h*canvasH`; the anchor is
  /// the rect center mapped to background NDC (origin center, y UP — so the
  /// top-left `frame.y` is flipped). Mirrors the iOS CGAffineTransform placement.
  private fun pipOverlaySettings(layer: OverlayLayer): OverlaySettings {
    val cx = layer.frameX + layer.frameW / 2.0
    val cy = layer.frameY + layer.frameH / 2.0
    val ndcX = (cx * 2.0 - 1.0).toFloat()
    val ndcY = (1.0 - cy * 2.0).toFloat()
    return OverlaySettings.Builder()
      .setScale(layer.frameW.toFloat(), layer.frameH.toFloat())
      .setBackgroundFrameAnchor(ndcX, ndcY)
      .build()
  }

  /// Builds one [EditedMediaItemSequence] from a list of clip specs, inserting a
  /// black-image item before any clip carrying a `leadingGapSec` (#18). Shared by
  /// [runMulti] and the composite base layer.
  private fun buildClipSequence(clipSpecs: List<Spec>, blackImage: File?): EditedMediaItemSequence {
    val first = clipSpecs.first()
    val seqBuilder = EditedMediaItemSequence.Builder()
    clipSpecs.forEach { clip ->
      if (clip.leadingGapSec > 1e-3 && blackImage != null) {
        val gapFps = (clip.fps?.roundToInt() ?: 30).coerceAtLeast(1)
        seqBuilder.addItem(
          EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(blackImage)))
            .setDurationUs((clip.leadingGapSec * 1_000_000.0).roundToLong())
            .setFrameRate(gapFps)
            .build()
        )
      }
      seqBuilder.addItem(
        EditedMediaItem.Builder(buildMediaItem(clip))
          .setEffects(Effects(emptyList(), buildVideoEffects(clip)))
          .setRemoveAudio(clip.removeAudio || first.audioReplacementUri != null)
          .build()
      )
    }
    return seqBuilder.build()
  }

  private fun runMultiInternal(
    context: Context,
    clipSpecs: List<Spec>,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
  ) {
    val first = clipSpecs.first()
    File(first.outputPath).apply { if (exists()) delete() }

    // A timeline gap (#18) is filled with a BLACK IMAGE item rendered as video
    // for the gap duration. Media3's addGap() is an audio-raw gap and does not
    // author black video, so an image item is used instead. One black PNG sized
    // to the shared canvas is reused for every gap and deleted on exit.
    val needGaps = clipSpecs.any { it.leadingGapSec > 1e-3 }
    val blackImage: File? =
      if (needGaps) authorBlackImage(context, first.outCanvasW, first.outCanvasH) else null
    try {
      // Passthrough keeps each clip's audio (Media3 concatenates the sequence);
      // mute / replace drop it per item (handled inside buildClipSequence).
      val videoSeq = buildClipSequence(clipSpecs, blackImage)

      val replaceUri = first.audioReplacementUri
      val composition = if (replaceUri != null) {
        val mediaItemBuilder = MediaItem.Builder().setUri(replaceUri)
        first.outputDurationSec?.let { durSec ->
          mediaItemBuilder.setClippingConfiguration(
            MediaItem.ClippingConfiguration.Builder()
              .setEndPositionMs((durSec * 1000.0).roundToLong())
              .build()
          )
        }
        val audioItem = EditedMediaItem.Builder(mediaItemBuilder.build())
          .setRemoveVideo(true)
          .build()
        Composition.Builder(videoSeq, EditedMediaItemSequence.Builder(audioItem).build()).build()
      } else {
        // The black image items carry no audio; for PASSTHROUGH gaps force a
        // continuous audio track so the source audio survives across the gaps as
        // silence. Never force it for mute (removeAudio) — that must stay
        // video-only.
        Composition.Builder(videoSeq)
          .experimentalSetForceAudioTrack(needGaps && !first.removeAudio)
          .build()
      }

      runTransformer(context, first.outputPath, first.hevc, first.bitrate, stopToken, progress) { transformer ->
        transformer.start(composition, first.outputPath)
      }
    } finally {
      blackImage?.delete()
    }
  }

  private fun runInternal(
    context: Context,
    spec: Spec,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
  ) {
    File(spec.outputPath).apply { if (exists()) delete() }

    // Replace drops the source audio and muxes a separate soundtrack in via a
    // parallel audio sequence (the video sequence drives the output duration,
    // so a longer replacement is truncated and a shorter one leaves a silent
    // tail). Mute drops audio; passthrough keeps it.
    val replaceUri = spec.audioReplacementUri
    val editedItem = EditedMediaItem.Builder(buildMediaItem(spec))
      .setEffects(Effects(emptyList(), buildVideoEffects(spec)))
      .setRemoveAudio(spec.removeAudio || replaceUri != null)
      .build()
    val composition: Composition? = replaceUri?.let { uri ->
      // Clip the replacement to the output video duration so a longer track
      // can't extend the export with an audio-only tail (Media3 sequence
      // ordering alone does not cap it). A shorter track leaves a silent tail.
      val mediaItemBuilder = MediaItem.Builder().setUri(uri)
      spec.outputDurationSec?.let { durSec ->
        mediaItemBuilder.setClippingConfiguration(
          MediaItem.ClippingConfiguration.Builder()
            .setEndPositionMs((durSec * 1000.0).roundToLong())
            .build()
        )
      }
      val audioItem = EditedMediaItem.Builder(mediaItemBuilder.build())
        .setRemoveVideo(true)
        .build()
      Composition.Builder(
        EditedMediaItemSequence.Builder(editedItem).build(),
        EditedMediaItemSequence.Builder(audioItem).build(),
      ).build()
    }

    runTransformer(context, spec.outputPath, spec.hevc, spec.bitrate, stopToken, progress) { transformer ->
      if (composition != null) {
        transformer.start(composition, spec.outputPath)
      } else {
        transformer.start(editedItem, spec.outputPath)
      }
    }
  }

  /// Shared Transformer lifecycle: builds a Transformer (HEVC / bitrate honoured),
  /// launches the export via [start] on the main Looper, polls cancellation +
  /// progress, and blocks until completion. Throws [CancelledException] on abort
  /// and [TransformerException] on export failure (deleting the partial output).
  private fun runTransformer(
    context: Context,
    outputPath: String,
    hevc: Boolean,
    bitrate: Int?,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
    start: (Transformer) -> Unit,
  ) {
    val mainHandler = Handler(Looper.getMainLooper())
    val latch = CountDownLatch(1)
    val exportError = AtomicReference<ExportException?>(null)
    val cancelled = AtomicBoolean(false)
    val transformerRef = AtomicReference<Transformer?>(null)

    mainHandler.post {
      val builder = Transformer.Builder(context)
      if (hevc) builder.setVideoMimeType(MimeTypes.VIDEO_H265)
      if (bitrate != null && bitrate > 0) {
        builder.setEncoderFactory(
          DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(
              VideoEncoderSettings.Builder().setBitrate(bitrate).build()
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
      start(transformer)
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
      File(outputPath).delete()
      throw CancelledException()
    }
    val err = exportError.get()
    if (err != null) {
      File(outputPath).delete()
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
