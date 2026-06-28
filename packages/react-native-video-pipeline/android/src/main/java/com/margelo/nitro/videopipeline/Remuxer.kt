///
/// Remuxer.kt
///
/// Android passthrough remux paths. Analogue of iOS RNVPRemuxer
/// (ios/Remuxer.{h,mm}) for the three entry points that land in T042:
///
///   * `remuxTrim` — single-source trim, compressed passthrough. Copies
///     samples inside [startSec, startSec+durationSec) from both video
///     and audio tracks into a new MP4. Rotation hint + container fields
///     propagate verbatim.
///   * `remuxConcat` — N-source concat onto a contiguous output timeline.
///     Rebases each source's PTS onto a running cursor. Requires every
///     source to share codec / dimensions / orientation with the first —
///     mismatches reject with InvalidSpec pointing at the T044 transcode
///     fallback (not wired yet in v0.1).
///   * `remuxStamp` — metadata-only stamp; compressed passthrough that
///     forwards the source sample stream and overlays new metadata items
///     onto the writer. `location` goes through `MediaMuxer.setLocation`;
///     the remaining MetadataSpec fields (software, creationDate,
///     description, custom) are persisted as `moov.udta.meta` mdta items
///     by `Mp4MetadataInjector` after the muxer closes — iOS parity.
///
/// The implementation uses plain MediaExtractor + MediaMuxer from the
/// Android SDK — no Media3 Transformer dependency. Transformer's
/// TransmuxOnly operation would cover the same ground but pulls in
/// ~3 MB of androidx.media3-* AARs; the PRD invariant is to keep
/// dependencies minimal for v0.1.
///
/// StopToken semantics mirror the iOS concat runner: the loop polls
/// `abortRequested()` at every sample boundary; on abort the partial
/// output file is deleted and the runner surfaces a CancelledException
/// whose message prefix lets `src/video.ts` map it back to a JS
/// `CancelledError`.
///

package com.margelo.nitro.videopipeline

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.roundToLong

internal object Remuxer {

  class InvalidSpecException(message: String) : IllegalArgumentException(message)

  class RemuxerException(message: String) : RuntimeException(message)

  class CancelledException : RuntimeException("VideoPipeline.render: Cancelled")

  data class ConcatSource(
    val uri: String,
    val sourceStart: Double,
    val sourceDuration: Double,
    val outputStart: Double,
  )

  /// Compressed-passthrough trim. Copies video (and audio when present)
  /// samples inside [startSec, startSec + durationSec). PTS is rebased to
  /// 0 in the output so playback starts at the trim's beginning.
  fun remuxTrim(
    sourceUri: String,
    outputPath: String,
    startSec: Double,
    durationSec: Double,
  ) {
    val sourcePath = resolveFilePath(sourceUri)
    requireSourceExists(sourcePath)
    if (startSec < 0.0) throw InvalidSpecException("trim: startSec must be >= 0 (got $startSec)")
    if (durationSec <= 0.0) {
      throw InvalidSpecException("trim: durationSec must be > 0 (got $durationSec)")
    }

    val sourceDurationSec = probeDurationSec(sourcePath)
    // startSec past EOF leaves zero frames to copy — reject. End-past-EOF is
    // silently clamped below (see `endUs` calc) to match AVAssetExportSession
    // / ffmpeg behavior; rejecting it would force every consumer to do
    // millisecond-precise duration arithmetic to avoid tripping on
    // muxer-vs-encoder rounding drift.
    if (startSec > sourceDurationSec + 1e-3) {
      throw InvalidSpecException(
        "trim: startSec ($startSec) exceeds source duration ($sourceDurationSec)"
      )
    }

    File(outputPath).apply { if (exists()) delete() }

    val extractor = MediaExtractor().apply { setDataSource(sourcePath) }
    try {
      val tracks = selectTracks(extractor)
      if (tracks.videoIndex < 0) {
        throw RemuxerException("trim: source has no video track")
      }

      val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
      try {
        propagateRotationHint(sourcePath, muxer)
        val outputTracks = addTracks(muxer, extractor, tracks)
        muxer.start()

        val startUs = (startSec * 1_000_000.0).roundToLong()
        // Clamp to source duration so an end-past-EOF request copies whatever
        // samples actually exist instead of overshooting the extractor's seek
        // range. See `describeTrimRejection` / Remuxer.cpp for the rationale.
        val sourceDurationUs = (sourceDurationSec * 1_000_000.0).roundToLong()
        val requestedEndUs = ((startSec + durationSec) * 1_000_000.0).roundToLong()
        val endUs = minOf(requestedEndUs, sourceDurationUs)
        copyRange(
          extractor = extractor,
          muxer = muxer,
          tracks = tracks,
          outputTracks = outputTracks,
          sourceStartUs = startUs,
          sourceEndUs = endUs,
          outputCursorUs = 0L,
          stopToken = null,
        )
        muxer.stop()
      } finally {
        muxer.release()
      }
    } catch (t: Throwable) {
      File(outputPath).delete()
      throw t
    } finally {
      extractor.release()
    }
  }

  /// Multi-source concat. All sources share codec / dimensions / orientation
  /// (mismatches reject with InvalidSpec). PTS is rebased onto a cumulative
  /// output cursor so playback sees a single continuous video.
  ///
  /// Audio: `AudioMode.PASSTHROUGH` (default) splices each clip's own audio
  /// onto the joined timeline; a clip without an audio track leaves a silent
  /// gap (the cursor advances regardless). `AudioMode.MUTE` writes video only.
  /// The output audio track is created from the first clip that carries audio,
  /// so passthrough concat assumes a shared audio format (same as the video
  /// signature requirement). `AudioMode.REPLACE` drops every clip's audio and
  /// muxes the soundtrack from `audioReplacementUri` instead, capped to the
  /// joined timeline's duration.
  fun remuxConcat(
    sources: List<ConcatSource>,
    outputPath: String,
    stopToken: VideoPipelineStopToken?,
    audioMode: AudioMode = AudioMode.PASSTHROUGH,
    audioReplacementUri: String? = null,
  ) {
    if (sources.isEmpty()) {
      throw InvalidSpecException("concat: sources must not be empty")
    }

    // Pre-abort shortcut — mirrors iOS RNVPRemuxer +remuxConcat's behaviour
    // where a flipped stop token before the export starts produces a
    // Cancelled error without touching the file system.
    if (stopToken?.isAbortRequested() == true) {
      throw CancelledException()
    }

    // JS-mirror pre-flight: contiguous starting at 0, no overlaps/gaps
    // beyond 1 ms rounding tolerance. Same gate the iOS
    // `describeConcatRejection` walker applies in cpp/engine/Remuxer.cpp.
    validateConcatTimeline(sources)

    val resolvedPaths = sources.map { resolveFilePath(it.uri) }
    resolvedPaths.forEachIndexed { i, path -> requireConcatSourceExists(i, path) }

    // Open every source once, enforce codec/size/rotation signature.
    val extractors = resolvedPaths.map {
      MediaExtractor().apply { setDataSource(it) }
    }
    // Replace: the soundtrack comes from a separate file, not the clips.
    val replace = audioMode == AudioMode.REPLACE && audioReplacementUri != null
    // Opened inside the try so a throwing setDataSource is still released by the
    // finally (and never leaks the clip extractors either).
    var replacementExtractor: MediaExtractor? = null
    try {
      if (replace) {
        val p = resolveFilePath(audioReplacementUri!!)
        if (!File(p).exists()) {
          throw RemuxerException("concat: audio replacement file not found at $p")
        }
        replacementExtractor = MediaExtractor().apply { setDataSource(p) }
      }
      val videoIndexes = extractors.map { selectVideoIndex(it) }
      val sharedFormat = enforceSharedSignature(extractors, videoIndexes, resolvedPaths)
      val rotation = readRotation(resolvedPaths[0])

      // Per-clip audio track index (-1 if the clip has no audio). Passthrough
      // splices each clip's audio; replace pulls a single soundtrack from the
      // replacement file; mute skips audio entirely.
      val audioIndexes = extractors.map { selectTracks(it).audioIndex }
      val replacementAudioIndex = replacementExtractor?.let { selectTracks(it).audioIndex } ?: -1
      // A replace render must not silently emit video-only.
      if (replace && replacementAudioIndex < 0) {
        throw InvalidSpecException(
          "concat: audio replace — the replacement file has no audio track"
        )
      }
      val firstAudioClip = when {
        audioMode == AudioMode.MUTE -> -1
        replace -> -1
        else -> audioIndexes.indexOfFirst { it >= 0 }
      }
      // The joined timeline uses a single output audio track, so every
      // passthrough clip that carries audio must share its format (a MediaMuxer
      // track can hold only one). Reject mismatches up front with a clear error
      // rather than letting writeSampleData fail late and leave a corrupt track.
      if (firstAudioClip >= 0) {
        enforceSharedAudioSignature(extractors, audioIndexes)
      }

      File(outputPath).apply { if (exists()) delete() }
      val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
      try {
        if (rotation != 0) muxer.setOrientationHint(rotation)
        val videoTrack = muxer.addTrack(sharedFormat)
        val audioTrack = when {
          replace && replacementAudioIndex >= 0 ->
            muxer.addTrack(replacementExtractor!!.getTrackFormat(replacementAudioIndex))
          firstAudioClip >= 0 ->
            muxer.addTrack(extractors[firstAudioClip].getTrackFormat(audioIndexes[firstAudioClip]))
          else -> -1
        }
        muxer.start()

        var outputCursorUs = 0L
        for (i in sources.indices) {
          if (stopToken?.isAbortRequested() == true) {
            throw CancelledException()
          }
          val extractor = extractors[i]
          val src = sources[i]
          val startUs = (src.sourceStart * 1_000_000.0).roundToLong()
          val endUs = ((src.sourceStart + src.sourceDuration) * 1_000_000.0).roundToLong()
          val copied = copyTrackRange(
            extractor = extractor,
            trackIndex = videoIndexes[i],
            muxer = muxer,
            outputTrack = videoTrack,
            sourceStartUs = startUs,
            sourceEndUs = endUs,
            outputCursorUs = outputCursorUs,
            stopToken = stopToken,
          )
          // Passthrough: splice this clip's audio over the same window. A clip
          // without audio leaves a silent gap; the cursor still advances by the
          // video span so later clips stay in sync. (Replace copies one
          // soundtrack after the loop; mute writes none.)
          if (!replace && audioTrack >= 0 && audioIndexes[i] >= 0) {
            copyTrackRange(
              extractor = extractor,
              trackIndex = audioIndexes[i],
              muxer = muxer,
              outputTrack = audioTrack,
              sourceStartUs = startUs,
              sourceEndUs = endUs,
              outputCursorUs = outputCursorUs,
              stopToken = stopToken,
            )
          }
          outputCursorUs += copied.durationUs
        }
        // Replace: mux the replacement soundtrack once over the whole joined
        // timeline, capped to its total duration (a shorter replacement leaves
        // a silent tail, a longer one is truncated).
        if (replace && audioTrack >= 0 && replacementAudioIndex >= 0) {
          copyTrackRange(
            extractor = replacementExtractor!!,
            trackIndex = replacementAudioIndex,
            muxer = muxer,
            outputTrack = audioTrack,
            sourceStartUs = 0L,
            sourceEndUs = outputCursorUs,
            outputCursorUs = 0L,
            stopToken = stopToken,
          )
        }
        muxer.stop()
      } catch (t: Throwable) {
        try { muxer.release() } catch (_: Throwable) {}
        File(outputPath).delete()
        throw t
      }
      muxer.release()
    } finally {
      extractors.forEach { runCatching { it.release() } }
      replacementExtractor?.let { runCatching { it.release() } }
    }
  }

  /// Metadata-only stamp. Copies compressed samples, sets `location` via
  /// `MediaMuxer.setLocation`, then persists the rest of the `MetadataSpec`
  /// (software / creationDate / description / custom) as `moov.udta.meta`
  /// mdta items via [Mp4MetadataInjector.injectSpec] — the same store iOS's
  /// AVAssetWriter writes, so the fields round-trip through `ProbeRunner`
  /// (description/creationDate into the dedicated `VideoInfo` fields,
  /// software/custom into `VideoInfo.custom`). Reaches iOS parity for
  /// container metadata. Also reused by the render metadata post-pass
  /// (`applyRenderMetadata`).
  fun remuxStamp(
    sourceUri: String,
    outputPath: String,
    metadata: MetadataSpec?,
  ) {
    val sourcePath = resolveFilePath(sourceUri)
    requireSourceExists(sourcePath)

    File(outputPath).apply { if (exists()) delete() }

    val extractor = MediaExtractor().apply { setDataSource(sourcePath) }
    try {
      val tracks = selectTracks(extractor)
      if (tracks.videoIndex < 0) {
        throw RemuxerException("stamp: source has no video track")
      }

      val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
      try {
        propagateRotationHint(sourcePath, muxer)
        // Geographic location is the only metadata field MediaMuxer exposes
        // natively on API 24+. Other fields in `metadata` are retained in the
        // JS-side type system but silently dropped at the container level on
        // Android v0.1.
        if (metadata?.location != null) {
          muxer.setLocation(metadata.location.latitude.toFloat(), metadata.location.longitude.toFloat())
        }
        val outputTracks = addTracks(muxer, extractor, tracks)
        muxer.start()

        val sourceDurationSec = probeDurationSec(sourcePath)
        val endUs = (sourceDurationSec * 1_000_000.0).roundToLong()
        copyRange(
          extractor = extractor,
          muxer = muxer,
          tracks = tracks,
          outputTracks = outputTracks,
          sourceStartUs = 0L,
          sourceEndUs = endUs,
          outputCursorUs = 0L,
          stopToken = null,
        )
        muxer.stop()
      } finally {
        muxer.release()
      }

      // MediaMuxer can only express `location` (setLocation, above). Persist
      // the rest of the MetadataSpec — software / creationDate / description /
      // custom — as moov.udta.meta mdta items, the same store iOS's
      // AVAssetWriter writes. Runs after the muxer closes the file; inside the
      // outer try, so a failure still deletes the half-written output.
      metadata?.let { Mp4MetadataInjector.injectSpec(outputPath, it) }
    } catch (t: Throwable) {
      File(outputPath).delete()
      throw t
    } finally {
      extractor.release()
    }
  }

  // --- internals ------------------------------------------------------

  private data class TrackSelection(val videoIndex: Int, val audioIndex: Int)
  private data class OutputTracks(val video: Int, val audio: Int)
  private data class CopiedRange(val sampleCount: Int, val durationUs: Long)

  private fun resolveFilePath(uri: String): String {
    return when {
      uri.startsWith("file://") -> uri.substring("file://".length)
      else -> uri
    }
  }

  private fun requireSourceExists(path: String) {
    if (!File(path).exists()) {
      throw RemuxerException("Source file not found: $path")
    }
  }

  private fun requireConcatSourceExists(index: Int, path: String) {
    if (!File(path).exists()) {
      throw RemuxerException("concat: clip[$index] not found at $path")
    }
  }

  private fun probeDurationSec(path: String): Double {
    val retriever = MediaMetadataRetriever()
    try {
      retriever.setDataSource(path)
      val durationMs = retriever
        .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
        ?.toLongOrNull() ?: 0L
      return durationMs / 1000.0
    } finally {
      runCatching { retriever.release() }
    }
  }

  private fun readRotation(path: String): Int {
    val retriever = MediaMetadataRetriever()
    try {
      retriever.setDataSource(path)
      return retriever
        .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
        ?.toIntOrNull() ?: 0
    } finally {
      runCatching { retriever.release() }
    }
  }

  private fun propagateRotationHint(sourcePath: String, muxer: MediaMuxer) {
    val rotation = readRotation(sourcePath)
    if (rotation != 0) muxer.setOrientationHint(rotation)
  }

  /// Whether `uri` resolves to an existing file that carries an audio track.
  /// Used to fail an `audio.mode = 'replace'` render loudly (rather than
  /// silently emitting video-only) when the replacement has no audio. Returns
  /// false for a missing or unreadable file.
  fun hasAudioTrack(uri: String): Boolean {
    val path = resolveFilePath(uri)
    if (!File(path).exists()) return false
    val ex = MediaExtractor()
    return try {
      ex.setDataSource(path)
      selectTracks(ex).audioIndex >= 0
    } catch (_: Throwable) {
      false
    } finally {
      ex.release()
    }
  }

  private fun selectTracks(extractor: MediaExtractor): TrackSelection {
    var videoIndex = -1
    var audioIndex = -1
    for (i in 0 until extractor.trackCount) {
      val format = extractor.getTrackFormat(i)
      val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
      when {
        videoIndex < 0 && mime.startsWith("video/") -> videoIndex = i
        audioIndex < 0 && mime.startsWith("audio/") -> audioIndex = i
      }
    }
    return TrackSelection(videoIndex, audioIndex)
  }

  private fun selectVideoIndex(extractor: MediaExtractor): Int {
    for (i in 0 until extractor.trackCount) {
      val format = extractor.getTrackFormat(i)
      val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
      if (mime.startsWith("video/")) return i
    }
    throw RemuxerException("concat: source has no video track")
  }

  private fun addTracks(
    muxer: MediaMuxer,
    extractor: MediaExtractor,
    tracks: TrackSelection,
  ): OutputTracks {
    val videoFormat = extractor.getTrackFormat(tracks.videoIndex)
    val outVideo = muxer.addTrack(videoFormat)
    val outAudio = if (tracks.audioIndex >= 0) {
      val audioFormat = extractor.getTrackFormat(tracks.audioIndex)
      muxer.addTrack(audioFormat)
    } else {
      -1
    }
    return OutputTracks(outVideo, outAudio)
  }

  /// Enforce codec + size + rotation equality across concat sources. Returns
  /// the MediaFormat of source[0] for use as the output track format.
  private fun enforceSharedSignature(
    extractors: List<MediaExtractor>,
    videoIndexes: List<Int>,
    paths: List<String>,
  ): MediaFormat {
    val firstFormat = extractors[0].getTrackFormat(videoIndexes[0])
    val firstMime = firstFormat.getString(MediaFormat.KEY_MIME) ?: "?"
    val firstW = firstFormat.getInteger(MediaFormat.KEY_WIDTH)
    val firstH = firstFormat.getInteger(MediaFormat.KEY_HEIGHT)
    val firstRotation = readRotation(paths[0])
    for (i in 1 until extractors.size) {
      val format = extractors[i].getTrackFormat(videoIndexes[i])
      val mime = format.getString(MediaFormat.KEY_MIME) ?: "?"
      val w = format.getInteger(MediaFormat.KEY_WIDTH)
      val h = format.getInteger(MediaFormat.KEY_HEIGHT)
      val rotation = readRotation(paths[i])
      if (mime != firstMime) {
        throw InvalidSpecException(
          "concat: clip[$i] codec '$mime' differs from clip[0] codec '$firstMime' — " +
            "transcode fallback lands in a later task"
        )
      }
      if (w != firstW || h != firstH) {
        throw InvalidSpecException(
          "concat: clip[$i] size ${w}x$h differs from clip[0] size ${firstW}x$firstH — " +
            "transcode fallback lands in a later task"
        )
      }
      if (rotation != firstRotation) {
        throw InvalidSpecException(
          "concat: clip[$i] rotation $rotation differs from clip[0] rotation $firstRotation — " +
            "normalize rotation first via Video.flip"
        )
      }
    }
    return firstFormat
  }

  /// Enforce a shared audio format across every concat clip that carries audio
  /// (clips without audio are skipped — they leave a silent gap). The joined
  /// timeline muxes into one audio track, which can hold only a single format,
  /// so a mismatch is rejected up front instead of failing late at
  /// writeSampleData with a corrupt/unplayable track.
  private fun enforceSharedAudioSignature(
    extractors: List<MediaExtractor>,
    audioIndexes: List<Int>,
  ) {
    fun intOrNull(format: MediaFormat, key: String): Int? =
      if (format.containsKey(key)) format.getInteger(key) else null
    // Codec-specific config (AAC ASC etc.). Two same-rate/channel tracks can
    // still carry different csd / AAC profile and would mux into one track as a
    // bad stream, so fold csd-0 + the AAC profile into the comparison.
    fun csd0(format: MediaFormat): List<Byte>? =
      if (format.containsKey("csd-0")) {
        val bb = format.getByteBuffer("csd-0")?.duplicate() ?: return@csd0 null
        ByteArray(bb.remaining()).also { bb.get(it) }.toList()
      } else {
        null
      }

    data class AudioSig(
      val mime: String,
      val rate: Int?,
      val channels: Int?,
      val profile: Int?,
      val csd: List<Byte>?,
    )
    fun sigOf(format: MediaFormat) = AudioSig(
      mime = format.getString(MediaFormat.KEY_MIME) ?: "?",
      rate = intOrNull(format, MediaFormat.KEY_SAMPLE_RATE),
      channels = intOrNull(format, MediaFormat.KEY_CHANNEL_COUNT),
      profile = intOrNull(format, MediaFormat.KEY_AAC_PROFILE),
      csd = csd0(format),
    )

    val withAudio = audioIndexes.withIndex().filter { it.value >= 0 }
    if (withAudio.size < 2) return
    val firstSig = sigOf(extractors[withAudio[0].index].getTrackFormat(withAudio[0].value))
    for (entry in withAudio.drop(1)) {
      val sig = sigOf(extractors[entry.index].getTrackFormat(entry.value))
      if (sig != firstSig) {
        throw InvalidSpecException(
          "concat: clip[${entry.index}] audio format (${sig.mime} ${sig.rate}Hz ${sig.channels}ch) " +
            "differs from clip[${withAudio[0].index}] (${firstSig.mime} ${firstSig.rate}Hz ${firstSig.channels}ch) — " +
            "a single concat output audio track needs an identical format " +
            "(codec, sample rate, channels, and codec config); the transcode " +
            "fallback lands in a later task"
        )
      }
    }
  }

  private fun validateConcatTimeline(sources: List<ConcatSource>) {
    var cursor = 0.0
    sources.forEachIndexed { i, s ->
      if (s.sourceStart < 0.0) {
        throw InvalidSpecException("concat: clip[$i].sourceStart must be >= 0")
      }
      if (s.sourceDuration <= 0.0) {
        throw InvalidSpecException("concat: clip[$i].sourceDuration must be > 0")
      }
      if (kotlin.math.abs(s.outputStart - cursor) > 1e-3) {
        throw InvalidSpecException(
          "concat: clip[$i].outputStart ($s.outputStart) must equal the cumulative output " +
            "timeline ($cursor) — gaps/overlaps require the transcode path"
        )
      }
      cursor += s.sourceDuration
    }
  }

  /// Copy the sample range [sourceStartUs, sourceEndUs) from each selected
  /// track into the output muxer, rebasing every output PTS so the range's
  /// anchor (the sync frame at/below `sourceStartUs`) lands at 0 (or at
  /// `outputCursorUs` when multiple ranges are concatenated).
  ///
  /// Trim precision is GOP-bounded. Without MP4 edit-list support in
  /// MediaMuxer we cannot hide the pre-roll that seekTo SEEK_TO_PREVIOUS_SYNC
  /// produces; the output therefore starts at the nearest I-frame at or
  /// before `sourceStartUs`. Fixtures authored by `VideoEncoder` use
  /// `KEY_I_FRAME_INTERVAL = 2` (seconds), so a 1s fixture's trim result
  /// is frame-accurate in practice — the first sample is always the frame
  /// at PTS 0.
  private fun copyRange(
    extractor: MediaExtractor,
    muxer: MediaMuxer,
    tracks: TrackSelection,
    outputTracks: OutputTracks,
    sourceStartUs: Long,
    sourceEndUs: Long,
    outputCursorUs: Long,
    stopToken: VideoPipelineStopToken?,
  ) {
    if (tracks.videoIndex >= 0) extractor.selectTrack(tracks.videoIndex)
    if (tracks.audioIndex >= 0) extractor.selectTrack(tracks.audioIndex)
    try {
      extractor.seekTo(sourceStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
      val anchorUs = extractor.sampleTime.coerceAtLeast(0L)
      val bufferInfo = MediaCodec.BufferInfo()
      val buffer = ByteBuffer.allocateDirect(DEFAULT_SAMPLE_BUFFER_BYTES)
      while (true) {
        if (stopToken?.isAbortRequested() == true) {
          throw CancelledException()
        }
        val trackIdx = extractor.sampleTrackIndex
        if (trackIdx < 0) break
        val pts = extractor.sampleTime
        if (pts < 0 || pts >= sourceEndUs) break
        val outTrack = when (trackIdx) {
          tracks.videoIndex -> outputTracks.video
          tracks.audioIndex -> outputTracks.audio
          else -> -1
        }
        if (outTrack < 0) {
          extractor.advance()
          continue
        }
        buffer.clear()
        val sampleSize = extractor.readSampleData(buffer, 0)
        if (sampleSize < 0) break
        bufferInfo.offset = 0
        bufferInfo.size = sampleSize
        bufferInfo.presentationTimeUs = max(0L, pts - anchorUs) + outputCursorUs
        bufferInfo.flags = extractorFlagsToBufferFlags(extractor.sampleFlags)
        muxer.writeSampleData(outTrack, buffer, bufferInfo)
        extractor.advance()
      }
    } finally {
      if (tracks.videoIndex >= 0) extractor.unselectTrack(tracks.videoIndex)
      if (tracks.audioIndex >= 0) extractor.unselectTrack(tracks.audioIndex)
    }
  }

  /// Video-only variant used by concat. Writes nothing for audio since v0.1
  /// concat drops audio (iOS T029 parity). Returns the written sample count
  /// and the wall-time span so the caller can advance the cumulative
  /// output cursor onto the next clip.
  /// Copy one source track's compressed samples in [sourceStartUs, sourceEndUs)
  /// to `outputTrack`, rebased onto `outputCursorUs`. Selects and unselects the
  /// track itself so video and audio can be copied in independent passes over
  /// the same extractor. Used by the concat path for both the video and the
  /// passthrough audio track.
  private fun copyTrackRange(
    extractor: MediaExtractor,
    trackIndex: Int,
    muxer: MediaMuxer,
    outputTrack: Int,
    sourceStartUs: Long,
    sourceEndUs: Long,
    outputCursorUs: Long,
    stopToken: VideoPipelineStopToken?,
  ): CopiedRange {
    extractor.selectTrack(trackIndex)
    try {
      extractor.seekTo(sourceStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
      val bufferInfo = MediaCodec.BufferInfo()
      val buffer = ByteBuffer.allocateDirect(DEFAULT_SAMPLE_BUFFER_BYTES)
      var sampleCount = 0
      var maxRelativeUs = 0L
      while (true) {
        if (stopToken?.isAbortRequested() == true) {
          throw CancelledException()
        }
        val trackIdx = extractor.sampleTrackIndex
        if (trackIdx < 0) break
        if (trackIdx != trackIndex) {
          extractor.advance()
          continue
        }
        val pts = extractor.sampleTime
        if (pts < 0 || pts >= sourceEndUs) break
        if (pts < sourceStartUs) {
          extractor.advance()
          continue
        }
        buffer.clear()
        val sampleSize = extractor.readSampleData(buffer, 0)
        if (sampleSize < 0) break
        bufferInfo.offset = 0
        bufferInfo.size = sampleSize
        val relativeUs = max(0L, pts - sourceStartUs)
        bufferInfo.presentationTimeUs = relativeUs + outputCursorUs
        bufferInfo.flags = extractorFlagsToBufferFlags(extractor.sampleFlags)
        muxer.writeSampleData(outputTrack, buffer, bufferInfo)
        sampleCount++
        maxRelativeUs = max(maxRelativeUs, relativeUs)
        extractor.advance()
      }
      // Duration = (requested end) - (requested start). Using the requested
      // span (not the highest sample PTS) keeps the output cursor aligned with
      // the caller's timeline even when the last sample lands before endUs.
      val durationUs = max(0L, sourceEndUs - sourceStartUs)
      return CopiedRange(sampleCount, durationUs)
    } finally {
      extractor.unselectTrack(trackIndex)
    }
  }

  private fun extractorFlagsToBufferFlags(extractorFlags: Int): Int {
    var flags = 0
    if ((extractorFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) {
      flags = flags or MediaCodec.BUFFER_FLAG_KEY_FRAME
    }
    return flags
  }

  private const val DEFAULT_SAMPLE_BUFFER_BYTES = 1 * 1024 * 1024
}
