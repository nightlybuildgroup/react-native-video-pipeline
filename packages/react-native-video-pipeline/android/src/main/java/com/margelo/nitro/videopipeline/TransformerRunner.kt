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
    compositionOverlays: List<Transcoder.ResolvedOverlay>,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
  ) {
    require(baseSpecs.isNotEmpty()) { "runCompositePip requires a base track" }
    require(overlays.isNotEmpty()) { "runCompositePip requires at least one overlay" }
    try {
      runCompositePipInternal(
        context, baseSpecs, overlays, totalDurationSec, compositionOverlays, stopToken, progress,
      )
    } finally {
      val all = baseSpecs.flatMap { it.overlays } +
        overlays.flatMap { it.spec.overlays } +
        compositionOverlays
      all.toHashSet().forEach { runCatching { it.bitmap.recycle() } }
    }
  }

  private fun runCompositePipInternal(
    context: Context,
    baseSpecs: List<Spec>,
    overlays: List<OverlayLayer>,
    totalDurationSec: Double,
    compositionOverlays: List<Transcoder.ResolvedOverlay>,
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

      // audio.mode = 'replace': the base clips were audio-stripped in
      // buildClipSequence (it strips when first.audioReplacementUri != null) and
      // overlay tracks always strip, so the only sound is the replacement, added
      // as a parallel audio-only sequence. Appended AFTER the video sequences so
      // it isn't a video-compositor input and doesn't shift the inputId→layer
      // mapping the compositor relies on (audio-only sequences are never passed
      // to getOverlaySettings).
      val replaceUri = first.audioReplacementUri
      val sequences = orderedSeqs.toMutableList()
      if (replaceUri != null) {
        sequences.add(replacementAudioSequence(replaceUri, first.outputDurationSec))
      }

      // The base's black gap-fill images carry no audio; for a gapped base with
      // passthrough audio, force a continuous audio track so the source audio
      // survives across the gaps as silence (same as runMulti). Never force it
      // when the base is muted or when a replacement soundtrack already supplies
      // a continuous audio track.
      val composition = Composition.Builder(sequences)
        .setVideoCompositorSettings(compositor)
        .experimentalSetForceAudioTrack(needBaseGaps && !first.removeAudio && replaceUri == null)
        .apply {
          // Static (spec-level) overlays composite on top of the whole PiP
          // output — a watermark's natural z-order (#52).
          compositionOverlayEffect(compositionOverlays, canvasW, canvasH)?.let { setEffects(it) }
        }
        .build()

      runTransformer(context, first.outputPath, first.hevc, first.bitrate, stopToken, progress) { transformer ->
        transformer.start(composition, first.outputPath)
      }
    } finally {
      blackImage?.delete()
      transparent.delete()
    }
  }

  /// A standalone audio-only [EditedMediaItemSequence] carrying the replacement
  /// soundtrack for `audio.mode = 'replace'`. Clipped to the output video
  /// duration so a longer track can't extend the export with an audio-only tail
  /// (Media3 sequence ordering alone does not cap it); a shorter track leaves a
  /// silent tail. Added as a parallel sequence alongside the (audio-stripped)
  /// video — shared by the single, multi-clip, and composite (PiP/crossfade)
  /// paths so they agree on replacement semantics.
  private fun replacementAudioSequence(
    replaceUri: String,
    outputDurationSec: Double?,
  ): EditedMediaItemSequence {
    val mediaItemBuilder = MediaItem.Builder().setUri(replaceUri)
    outputDurationSec?.let { durSec ->
      mediaItemBuilder.setClippingConfiguration(
        MediaItem.ClippingConfiguration.Builder()
          .setEndPositionMs((durSec * 1000.0).roundToLong())
          .build()
      )
    }
    val audioItem = EditedMediaItem.Builder(mediaItemBuilder.build())
      .setRemoveVideo(true)
      .build()
    return EditedMediaItemSequence.Builder(audioItem).build()
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

  /// One clip on the crossfade timeline (#43). `spec` is its trim/transform
  /// (presented to the shared canvas); `outputStartSec`/`effDurSec` place it.
  data class CrossfadeClip(
    val spec: Spec,
    val outputStartSec: Double,
    val effDurSec: Double,
  )

  /// Timeline-overlap crossfade (#43 — Android parity with iOS #18). Adjacent
  /// clips whose windows overlap are dissolved over the overlap region. Built on
  /// two **ping-pong** `EditedMediaItemSequence`s (clip i on sequence `i % 2`),
  /// so an overlapping pair always lands on distinct sequences and can coexist in
  /// time; each sequence is padded with transparent images so both span the full
  /// output duration. Media3 draws sequence 0 on top, so a `VideoCompositorSettings`
  /// ramps **sequence 0's** alpha across each overlap window — `1→0` when
  /// sequence 0 holds the outgoing (earlier) clip, `0→1` when it holds the
  /// incoming clip; either way the visible result dissolves outgoing→incoming.
  /// Sequence 1 stays opaque. Audio (passthrough) is volume-ramped per clip via
  /// [VolumeRampAudioProcessor] so the overlap sums to a crossfade, not a bump.
  fun runCompositeCrossfade(
    context: Context,
    clips: List<CrossfadeClip>,
    totalDurationSec: Double,
    compositionOverlays: List<Transcoder.ResolvedOverlay>,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
  ) {
    require(clips.size >= 2) { "runCompositeCrossfade requires at least two clips" }
    try {
      runCompositeCrossfadeInternal(
        context, clips, totalDurationSec, compositionOverlays, stopToken, progress,
      )
    } finally {
      val all = clips.flatMap { it.spec.overlays } + compositionOverlays
      all.toHashSet().forEach { runCatching { it.bitmap.recycle() } }
    }
  }

  private class OverlapWindow(val start: Double, val end: Double, val seq0IsOutgoing: Boolean)

  private fun runCompositeCrossfadeInternal(
    context: Context,
    clips: List<CrossfadeClip>,
    totalDurationSec: Double,
    compositionOverlays: List<Transcoder.ResolvedOverlay>,
    stopToken: VideoPipelineStopToken?,
    progress: ProgressSink?,
  ) {
    val first = clips.first().spec
    val canvasW = first.outCanvasW.coerceAtLeast(2)
    val canvasH = first.outCanvasH.coerceAtLeast(2)
    File(first.outputPath).apply { if (exists()) delete() }

    fun clipEnd(i: Int) = clips[i].outputStartSec + clips[i].effDurSec

    // Overlap windows between adjacent clips. seq0IsOutgoing is true when the
    // outgoing (earlier) clip i is on sequence 0 (even index) — then seq0's alpha
    // ramps 1→0; otherwise seq0 holds the incoming clip and ramps 0→1.
    val overlaps = ArrayList<OverlapWindow>()
    for (i in 0 until clips.size - 1) {
      val end = clipEnd(i)
      val nextStart = clips[i + 1].outputStartSec
      if (nextStart < end - 1e-3) {
        overlaps.add(OverlapWindow(nextStart, end, seq0IsOutgoing = i % 2 == 0))
      }
    }

    // Passthrough audio (not muted) is carried on SEPARATE audio-only sequences,
    // not on the video sequences. A video ping-pong sequence leads with a
    // transparent image pad, and Media3 cannot reconcile a sequence whose first
    // item (an image) has no audio while a later item does — it throws an
    // asset-loader error with or without a forced audio track. So the video
    // sequences are always audio-stripped, and the audio rides its own pair of
    // ping-pong sequences positioned with `addGap` (proper silent audio).
    // Build the audio sequences only when audio is actually carried: passthrough
    // (not muted) AND at least one source clip has an audio track. A clip with no
    // audio contributes silence (an `addGap` of its span) so the envelope on the
    // audio-bearing clips stays time-aligned.
    // audio.mode = 'replace' drops the per-clip ramped soundtracks entirely and
    // muxes a single replacement sequence instead (built below). Passthrough
    // (the default) ramps each source clip's audio over its overlap windows.
    val replaceUri = first.audioReplacementUri
    val clipHasAudio = clips.map { runCatching { Remuxer.hasAudioTrack(it.spec.sourceUri) }.getOrDefault(false) }
    val buildAudio = replaceUri == null && !first.removeAudio && clipHasAudio.any { it }
    val transparent = authorTransparentImage(context, canvasW, canvasH)
    try {
      val videoBuilders = Array(2) { EditedMediaItemSequence.Builder() }
      val audioBuilders = Array(2) { EditedMediaItemSequence.Builder() }
      val vCursor = doubleArrayOf(0.0, 0.0)
      val aCursor = doubleArrayOf(0.0, 0.0)
      val padFps = (first.fps?.roundToInt() ?: 30).coerceAtLeast(1)
      clips.forEachIndexed { i, clip ->
        val p = i % 2
        // VIDEO ping-pong: audio-stripped clip, transparent-padded into place.
        val vLead = (clip.outputStartSec - vCursor[p]).coerceAtLeast(0.0)
        if (vLead > 1e-3) videoBuilders[p].addItem(transparentItem(transparent, vLead, padFps))
        videoBuilders[p].addItem(buildCrossfadeVideoItem(clip))
        vCursor[p] = clip.outputStartSec + clip.effDurSec
        // AUDIO ping-pong: video-stripped clip placed after a silent gap, with the
        // head/tail volume ramp. Head ramps when this clip is the incoming side of
        // an overlap with the previous clip; tail when it is the outgoing side of
        // an overlap with the next. A clip with no audio becomes a plain silence
        // gap so the next clip's audio still lands at its outputStart.
        if (buildAudio) {
          val aLead = (clip.outputStartSec - aCursor[p]).coerceAtLeast(0.0)
          if (aLead > 1e-3) audioBuilders[p].addGap((aLead * 1_000_000.0).roundToLong())
          if (clipHasAudio[i]) {
            val headSec =
              if (i > 0) (clipEnd(i - 1) - clip.outputStartSec).coerceAtLeast(0.0) else 0.0
            val tailSec =
              if (i < clips.size - 1) (clipEnd(i) - clips[i + 1].outputStartSec).coerceAtLeast(0.0) else 0.0
            audioBuilders[p].addItem(buildCrossfadeAudioItem(clip, headSec, tailSec))
          } else {
            audioBuilders[p].addGap((clip.effDurSec * 1_000_000.0).roundToLong())
          }
          aCursor[p] = clip.outputStartSec + clip.effDurSec
        }
      }
      for (p in 0..1) {
        val trail = (totalDurationSec - vCursor[p]).coerceAtLeast(0.0)
        if (trail > 1e-3) videoBuilders[p].addItem(transparentItem(transparent, trail, padFps))
      }
      // Video sequences first (sequence 0 = the top compositor layer), then the
      // audio-only sequences. Audio-only sequences carry no video, so they are
      // not compositor inputs and do not affect the alpha-ramp mapping.
      val sequences = mutableListOf(videoBuilders[0].build(), videoBuilders[1].build())
      if (buildAudio) {
        sequences.add(audioBuilders[0].build())
        sequences.add(audioBuilders[1].build())
      } else if (replaceUri != null) {
        sequences.add(replacementAudioSequence(replaceUri, first.outputDurationSec))
      }

      val compositor = object : VideoCompositorSettings {
        override fun getOutputSize(inputSizes: MutableList<Size>): Size = Size(canvasW, canvasH)

        override fun getOverlaySettings(inputId: Int, presentationTimeUs: Long): OverlaySettings {
          // Sequence 1 (bottom) is always opaque; only sequence 0 (top) ramps.
          if (inputId != 0) return OverlaySettings.Builder().build()
          val tSec = presentationTimeUs / 1_000_000.0
          for (ov in overlaps) {
            if (tSec >= ov.start - 1e-3 && tSec <= ov.end + 1e-3) {
              val span = (ov.end - ov.start).coerceAtLeast(1e-6)
              val progressFrac = ((tSec - ov.start) / span).coerceIn(0.0, 1.0)
              val alpha = if (ov.seq0IsOutgoing) 1.0 - progressFrac else progressFrac
              return OverlaySettings.Builder().setAlphaScale(alpha.toFloat()).build()
            }
          }
          return OverlaySettings.Builder().build()
        }
      }

      val composition = Composition.Builder(sequences)
        .setVideoCompositorSettings(compositor)
        .apply {
          // Static (spec-level) overlays composite on top of the dissolved
          // output — a watermark's natural z-order (#52).
          compositionOverlayEffect(compositionOverlays, canvasW, canvasH)?.let { setEffects(it) }
        }
        .build()

      runTransformer(context, first.outputPath, first.hevc, first.bitrate, stopToken, progress) { transformer ->
        transformer.start(composition, first.outputPath)
      }
    } finally {
      transparent.delete()
    }
  }

  /// The video half of a crossfade clip: trim/transform effects, audio stripped
  /// (the audio rides a separate sequence — see [runCompositeCrossfadeInternal]).
  private fun buildCrossfadeVideoItem(clip: CrossfadeClip): EditedMediaItem =
    EditedMediaItem.Builder(buildMediaItem(clip.spec))
      .setEffects(Effects(emptyList(), buildVideoEffects(clip.spec)))
      .setRemoveAudio(true)
      .build()

  /// The audio half of a crossfade clip: video stripped, with the head/tail
  /// [VolumeRampAudioProcessor] envelope over its overlap windows.
  private fun buildCrossfadeAudioItem(clip: CrossfadeClip, headSec: Double, tailSec: Double): EditedMediaItem {
    val audioProcessors: List<androidx.media3.common.audio.AudioProcessor> =
      if (headSec > 1e-3 || tailSec > 1e-3) {
        listOf(VolumeRampAudioProcessor(clip.effDurSec, headSec, tailSec))
      } else {
        emptyList()
      }
    return EditedMediaItem.Builder(buildMediaItem(clip.spec))
      .setRemoveVideo(true)
      .setEffects(Effects(audioProcessors, emptyList()))
      .build()
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
        Composition.Builder(
          videoSeq,
          replacementAudioSequence(replaceUri, first.outputDurationSec),
        ).build()
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
      Composition.Builder(
        EditedMediaItemSequence.Builder(editedItem).build(),
        replacementAudioSequence(uri, spec.outputDurationSec),
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
      throw TransformerException(describeExportException(err))
    }
  }

  /// Build a diagnosable, single-line description of a Media3 [ExportException]
  /// for the message thrown across the JS boundary. Media3 otherwise surfaces
  /// only its human `message` (when non-null), which hides the actionable,
  /// greppable structured signal: the symbolic `errorCodeName` (+ the raw
  /// `errorCode`) and the `cause` chain that carries the real MediaCodec / IO
  /// exception. This always surfaces all of it inline — issue #89, parity with
  /// iOS #85 / `RNVPDescribeError`. e.g.:
  ///
  ///   Media3 export failed (Media3 ExportException ERROR_CODE_IO_FILE_NOT_FOUND
  ///   [2001]; cause: java.io.FileNotFoundException: /bad/dir/out.mp4; hint: …)
  ///
  /// Split from the throw site so the offline Kotlin test suite can exercise the
  /// formatting directly; [hintForExportErrorCode] is likewise exposed so the
  /// known-code hints are unit-testable in isolation.
  internal fun describeExportException(err: ExportException): String {
    val base = err.message?.takeIf { it.isNotEmpty() } ?: "Media3 export failed"
    val sb = StringBuilder(base)
    sb.append(" (Media3 ExportException ")
      .append(err.errorCodeName)
      .append(" [").append(err.errorCode).append(']')
    err.cause?.let { cause ->
      sb.append("; cause: ")
      appendCauseChain(cause, sb, 0)
    }
    hintForExportErrorCode(err.errorCode)?.let { hint ->
      sb.append("; hint: ").append(hint)
    }
    sb.append(')')
    return sb.toString()
  }

  /// Append "<class>: <message>" for `t`, then recurse into its `cause`
  /// (guarded against a pathological cycle and self-reference), mirroring the
  /// `NSUnderlyingError` walk in iOS `RNVPDescribeError`.
  private fun appendCauseChain(t: Throwable, sb: StringBuilder, depth: Int) {
    sb.append(t.javaClass.name)
    t.message?.takeIf { it.isNotEmpty() }?.let { sb.append(": ").append(it) }
    val next = t.cause
    if (next != null && next !== t) {
      if (depth >= 8) {
        sb.append("; caused by (…truncated)")
        return
      }
      sb.append("; caused by ")
      appendCauseChain(next, sb, depth + 1)
    }
  }

  /// A human hint for the export `errorCode`s a consumer is most likely to hit
  /// and can act on (issue #89), or null if the code isn't mapped — parity with
  /// iOS `RNVPHintForErrorCode`. Exposed for testing; [describeExportException]
  /// folds it into its output.
  internal fun hintForExportErrorCode(errorCode: Int): String? = when (errorCode) {
    ExportException.ERROR_CODE_IO_FILE_NOT_FOUND,
    ExportException.ERROR_CODE_IO_NO_PERMISSION ->
      "Media3 could not open the output file — verify the parent directory " +
        "exists and output.path is a writable filesystem path, not a " +
        "content:// or asset URI"
    ExportException.ERROR_CODE_ENCODER_INIT_FAILED,
    ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED ->
      "the device encoder rejected the requested output format — try H.264 " +
        "at a lower resolution/bitrate, or a codec this device supports"
    else -> null
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
      // LAYOUT_STRETCH_TO_FIT, not SCALE_TO_FIT: the content is scaled
      // non-uniformly to exactly fill the canvas, matching iOS, where the
      // transcoder applies a non-uniform CGAffineTransformMakeScale to the
      // render size (Transcoder.mm "Final scale to exactly the encoder target
      // dimensions"). With SCALE_TO_FIT, an asymmetric canvas (e.g. a single
      // pinned dimension whose fallback axis differs in aspect from the source)
      // letterboxes/pillarboxes instead of filling, diverging from iOS. The
      // output *frame* size is identical under either layout — Media3's
      // Presentation.configure() returns the requested width×height regardless;
      // only the in-frame content scaling differs.
      effects.add(
        Presentation.createForWidthAndHeight(
          spec.outCanvasW, spec.outCanvasH, Presentation.LAYOUT_STRETCH_TO_FIT
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

  /// Composition-level video [Effects] for static (spec-level) overlays, anchored
  /// to the output canvas exactly like the single-clip transcode overlays. Applied
  /// via `Composition.Builder.setEffects`, so they composite on top of the final
  /// PiP/crossfade frame — the natural z-order for a watermark (#52). Returns null
  /// when there are no static overlays (nothing to set).
  private fun compositionOverlayEffect(
    overlays: List<Transcoder.ResolvedOverlay>,
    canvasW: Int,
    canvasH: Int,
  ): Effects? {
    if (overlays.isEmpty()) return null
    val w = canvasW.coerceAtLeast(1)
    val h = canvasH.coerceAtLeast(1)
    val textureOverlays = overlays.map { buildOverlay(it, w, h) }
    return Effects(emptyList(), listOf(OverlayEffect(ArrayList<TextureOverlay>(textureOverlays))))
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
