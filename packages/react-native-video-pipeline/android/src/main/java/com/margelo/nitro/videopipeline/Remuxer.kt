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
///     onto the writer. On Android v0.1 only GPS is settable via
///     `MediaMuxer.setLocation(lat, lon)`; the other MetadataSpec fields
///     (software, creationDate, description, custom) are accepted without
///     error but aren't persisted to the container — the transcode stamp
///     path (T044 follow-up) is where full metadata authoring lands.
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
    if (startSec + durationSec > sourceDurationSec + 1e-3) {
      throw InvalidSpecException(
        "trim: startSec + durationSec (${startSec + durationSec}) exceeds source duration " +
          "($sourceDurationSec)"
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
        val endUs = ((startSec + durationSec) * 1_000_000.0).roundToLong()
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
  /// output cursor so playback sees a single continuous video. Audio is
  /// dropped in v0.1 — the concat silent-audio authoring lands on the
  /// transcode path later, matching iOS T029's scope.
  fun remuxConcat(
    sources: List<ConcatSource>,
    outputPath: String,
    stopToken: VideoPipelineStopToken?,
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
    try {
      val videoIndexes = extractors.map { selectVideoIndex(it) }
      val sharedFormat = enforceSharedSignature(extractors, videoIndexes, resolvedPaths)
      val rotation = readRotation(resolvedPaths[0])

      File(outputPath).apply { if (exists()) delete() }
      val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
      try {
        if (rotation != 0) muxer.setOrientationHint(rotation)
        val videoTrack = muxer.addTrack(sharedFormat)
        muxer.start()

        var outputCursorUs = 0L
        for (i in sources.indices) {
          if (stopToken?.isAbortRequested() == true) {
            throw CancelledException()
          }
          val extractor = extractors[i]
          extractor.selectTrack(videoIndexes[i])
          val src = sources[i]
          val startUs = (src.sourceStart * 1_000_000.0).roundToLong()
          val endUs = ((src.sourceStart + src.sourceDuration) * 1_000_000.0).roundToLong()
          val copied = copyVideoOnly(
            extractor = extractor,
            videoTrackIndex = videoIndexes[i],
            muxer = muxer,
            outputVideoTrack = videoTrack,
            sourceStartUs = startUs,
            sourceEndUs = endUs,
            outputCursorUs = outputCursorUs,
            stopToken = stopToken,
          )
          outputCursorUs += copied.durationUs
          extractor.unselectTrack(videoIndexes[i])
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
    }
  }

  /// Metadata-only stamp. Copies compressed samples + sets whatever
  /// metadata MediaMuxer can express natively — GPS today via setLocation.
  /// Non-GPS fields in the provided MetadataSpec are accepted without
  /// error but not persisted in v0.1; full metadata authoring (software,
  /// creationDate, description, custom keys) lands on the transcode stamp
  /// path in T044. This mirrors the iOS metadata-only remux in T032 which
  /// has the full suite — Android catches up when the writer can express
  /// more than the container default.
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
        // GNSS is the only metadata field MediaMuxer exposes natively on API 24+.
        // Other fields in `metadata` are retained in the JS-side type system
        // but silently dropped at the container level on Android v0.1.
        if (metadata?.gnss != null) {
          muxer.setLocation(metadata.gnss.latitude.toFloat(), metadata.gnss.longitude.toFloat())
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
  private fun copyVideoOnly(
    extractor: MediaExtractor,
    videoTrackIndex: Int,
    muxer: MediaMuxer,
    outputVideoTrack: Int,
    sourceStartUs: Long,
    sourceEndUs: Long,
    outputCursorUs: Long,
    stopToken: VideoPipelineStopToken?,
  ): CopiedRange {
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
      if (trackIdx != videoTrackIndex) {
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
      muxer.writeSampleData(outputVideoTrack, buffer, bufferInfo)
      sampleCount++
      maxRelativeUs = max(maxRelativeUs, relativeUs)
      extractor.advance()
    }
    // Duration = (requested end) - (requested start). Using the requested
    // span (not the highest sample PTS) keeps the output cursor aligned with
    // the caller's timeline even when the last sample lands before endUs.
    val durationUs = max(0L, sourceEndUs - sourceStartUs)
    return CopiedRange(sampleCount, durationUs)
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
