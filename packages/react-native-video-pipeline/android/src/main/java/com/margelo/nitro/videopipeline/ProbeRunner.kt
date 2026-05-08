///
/// ProbeRunner.kt
///
/// Android analogue of iOS RNVPAVDemuxer + RNVPThumbnailer + RNVPCapabilities
/// for the three probe entry points in T043:
///
///   * `info(uri)` — MediaExtractor + MediaMetadataRetriever. Returns the
///     same VideoInfo shape as iOS: codec/container strings, duration,
///     dimensions, fps, bit rate, rotation, HDR flag, creation date,
///     GPS, and an everything-else `custom` map.
///   * `thumbnail(uri, options)` — MediaMetadataRetriever.getFrameAtTime
///     with optional longest-side resize, rotation baked in, written as
///     JPEG at quality 90 (matches iOS Thumbnailer's 0.9 quality).
///   * `capabilities()` — MediaCodecList encoder probe for video/avc and
///     video/hevc. Cached after first call.
///
/// Zero external dependencies (no Media3, no FFmpeg) — plain android.media
/// APIs that exist since API 24.
///

package com.margelo.nitro.videopipeline

import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.io.File
import java.io.FileOutputStream
import java.time.Instant
import java.time.format.DateTimeFormatter
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

internal object ProbeRunner {

  class InvalidSpecException(message: String) : IllegalArgumentException(message)

  class ProbeException(message: String) : RuntimeException(message)

  class NotFoundException(message: String) : RuntimeException(message)

  // --- info ------------------------------------------------------------

  fun info(uri: String): VideoInfo {
    val path = resolveFilePath(uri)
    if (!File(path).exists()) {
      throw NotFoundException("No file at $path")
    }

    val extractor = MediaExtractor()
    val retriever = MediaMetadataRetriever()
    try {
      extractor.setDataSource(path)
      val videoTrackIndex = selectVideoTrack(extractor)
      val videoFormat = extractor.getTrackFormat(videoTrackIndex)
      val hasAudio = hasAudioTrack(extractor)
      retriever.setDataSource(path)

      val mime = videoFormat.getString(MediaFormat.KEY_MIME) ?: ""
      val codec = canonicalCodec(mime)
      val width = videoFormat.getInteger(MediaFormat.KEY_WIDTH, 0)
      val height = videoFormat.getInteger(MediaFormat.KEY_HEIGHT, 0)
      val fps = readFrameRate(videoFormat)
      val bitRate = readBitRate(videoFormat, retriever)
      val durationSec = readDurationSec(videoFormat, retriever)
      val rotation = readRotation(videoFormat, retriever)
      val isHDR = readIsHDR(videoFormat)
      val container = containerFromPath(path)

      val creationDate = parseCreationDate(
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE)
      )
      val gnss = parseISO6709(
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION)
      )
      // MediaMetadataRetriever exposes only a fixed set of well-known keys.
      // For arbitrary `mdta/<key>` items (and classic `udta/©…` atoms) we
      // walk the MP4 box tree directly and merge the result.
      val custom = LinkedHashMap<String, String>()
      custom.putAll(collectCustomMetadata(retriever))
      val mp4Items = try {
        Mp4MetadataInjector.read(path)
      } catch (_: Throwable) {
        emptyMap()
      }
      for ((k, v) in mp4Items) {
        if (custom[k] == null) custom[k] = v
      }

      val fileSizeBytes = try {
        java.io.File(path).length().toDouble()
      } catch (_: Throwable) {
        0.0
      }

      return VideoInfo(
        uri = uri,
        durationSec = durationSec,
        width = width.toDouble(),
        height = height.toDouble(),
        fps = fps,
        bitRate = bitRate.toDouble(),
        fileSizeBytes = fileSizeBytes,
        codec = codec,
        container = container,
        hasAudio = hasAudio,
        isHDR = isHDR,
        rotation = rotation.toDouble(),
        creationDate = creationDate,
        gnss = gnss,
        // MediaMetadataRetriever has no DESCRIPTION key; surfacing this on
        // Android requires walking the MP4 box tree (`udta/©cmt` etc.).
        // Mirror the spec doc until that lands — iOS already populates it.
        description = null,
        custom = custom.ifEmpty { null },
      )
    } catch (e: NotFoundException) {
      throw e
    } catch (e: InvalidSpecException) {
      throw e
    } catch (t: Throwable) {
      throw ProbeException("VideoPipeline.info failed: ${t.message ?: t::class.java.simpleName}")
    } finally {
      extractor.release()
      try { retriever.release() } catch (_: Throwable) {}
    }
  }

  // --- thumbnail -------------------------------------------------------

  fun thumbnail(uri: String, atSec: Double, outPath: String, resizeW: Double, resizeH: Double): String {
    if (!(atSec >= 0.0)) {
      throw InvalidSpecException("atSec must be >= 0")
    }
    if (outPath.isEmpty()) {
      throw InvalidSpecException("outPath must not be empty")
    }
    val sourcePath = resolveFilePath(uri)
    if (!File(sourcePath).exists()) {
      throw NotFoundException("Source file does not exist: $sourcePath")
    }

    val retriever = MediaMetadataRetriever()
    try {
      retriever.setDataSource(sourcePath)

      val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
        ?.toLongOrNull() ?: 0L
      val durationSec = durationMs / 1000.0
      val clamped = if (durationSec > 0.0 && atSec > durationSec) durationSec else atSec
      val timeUs = (clamped * 1_000_000.0).roundToLong()

      // OPTION_CLOSEST = nearest frame (may be non-sync) — matches iOS
      // AVAssetImageGenerator with zero tolerance.
      val raw = retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
        ?: throw ProbeException("MediaMetadataRetriever.getFrameAtTime returned null")

      // Bake rotation in. On some OEMs getFrameAtTime already rotates; on
      // others (especially pre-API 30) it returns the raw unrotated frame.
      // Be defensive by inspecting METADATA_KEY_VIDEO_ROTATION and rotating
      // to match if the bitmap orientation doesn't reflect it. Detection is
      // best-effort: if the bitmap's w/h already matches the rotated width
      // reported by METADATA_KEY_VIDEO_{WIDTH,HEIGHT}, skip the extra rotate.
      val rotationDeg = retriever.extractMetadata(
        MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION
      )?.toIntOrNull() ?: 0
      val metaW = retriever.extractMetadata(
        MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH
      )?.toIntOrNull() ?: raw.width
      val metaH = retriever.extractMetadata(
        MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT
      )?.toIntOrNull() ?: raw.height
      val rotated = applyRotationIfNeeded(raw, rotationDeg, metaW, metaH)

      val scaled = resizeLongestSide(
        src = rotated,
        targetW = resizeW,
        targetH = resizeH,
      )

      val outFile = File(outPath)
      outFile.parentFile?.mkdirs()
      if (outFile.exists()) outFile.delete()

      FileOutputStream(outFile).use { fos ->
        val ok = scaled.compress(Bitmap.CompressFormat.JPEG, 90, fos)
        if (!ok) {
          outFile.delete()
          throw ProbeException("Bitmap.compress(JPEG) returned false")
        }
      }

      if (scaled !== rotated) scaled.recycle()
      if (rotated !== raw) rotated.recycle()
      raw.recycle()

      return outPath
    } catch (e: NotFoundException) {
      throw e
    } catch (e: InvalidSpecException) {
      throw e
    } catch (t: Throwable) {
      throw ProbeException("VideoPipeline.thumbnail failed: ${t.message ?: t::class.java.simpleName}")
    } finally {
      try { retriever.release() } catch (_: Throwable) {}
    }
  }

  // --- capabilities ----------------------------------------------------

  @Volatile
  private var cachedCaps: EncoderCaps? = null
  private val capsLock = Any()

  fun capabilities(): EncoderCaps {
    val cached = cachedCaps
    if (cached != null) return cached
    synchronized(capsLock) {
      val again = cachedCaps
      if (again != null) return again
      val probed = runCapabilitiesProbe()
      cachedCaps = probed
      return probed
    }
  }

  // Visible for tests / future instrumentation — the self-test invoker on
  // Android is via App.tsx, but exposing the reset lets a future XCTest-
  // equivalent JNI test wipe the cache.
  fun resetCapabilitiesCacheForTesting() {
    synchronized(capsLock) {
      cachedCaps = null
    }
  }

  private fun runCapabilitiesProbe(): EncoderCaps {
    val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
    val h264 = findEncoderCapabilities(codecList, "video/avc")
    val hevc = findEncoderCapabilities(codecList, "video/hevc")

    val codecs = buildList {
      if (h264 != null) add(VideoCodec.H264)
      if (hevc != null) add(VideoCodec.HEVC)
    }.toTypedArray()

    // Ceiling is the larger of H.264 and HEVC video-capability ranges.
    // Matches iOS's "probe 4K @ H.264; fall back to 1080p" ceiling contract.
    var maxW = 0
    var maxH = 0
    var maxFps = 0.0
    var maxBitrate = 0L
    for (caps in listOfNotNull(h264, hevc)) {
      val vc = caps.videoCapabilities ?: continue
      maxW = max(maxW, vc.supportedWidths.upper)
      maxH = max(maxH, vc.supportedHeights.upper)
      maxFps = max(maxFps, vc.supportedFrameRates.upper.toDouble())
      maxBitrate = max(maxBitrate, vc.bitrateRange.upper.toLong())
    }
    // Sensible fallbacks if MediaCodecList returned nothing (e.g. headless
    // emulator with no codec list) — any Android-capable device reports at
    // least 1080p/30/10Mbps for H.264.
    if (maxW == 0) maxW = 1920
    if (maxH == 0) maxH = 1080
    if (maxFps == 0.0) maxFps = 30.0
    if (maxBitrate == 0L) maxBitrate = 10_000_000L

    val hdr = hevc != null && hevcSupportsMain10(hevc)

    return EncoderCaps(
      codecs = codecs,
      maxWidth = maxW.toDouble(),
      maxHeight = maxH.toDouble(),
      maxFps = maxFps,
      maxBitrate = maxBitrate.toDouble(),
      hdr = hdr,
    )
  }

  private fun findEncoderCapabilities(
    codecList: MediaCodecList,
    mime: String,
  ): MediaCodecInfo.CodecCapabilities? {
    for (info in codecList.codecInfos) {
      if (!info.isEncoder) continue
      val types = info.supportedTypes
      if (types.any { it.equals(mime, ignoreCase = true) }) {
        return try {
          info.getCapabilitiesForType(mime)
        } catch (_: Throwable) {
          null
        }
      }
    }
    return null
  }

  private fun hevcSupportsMain10(caps: MediaCodecInfo.CodecCapabilities): Boolean {
    val profiles = caps.profileLevels ?: return false
    return profiles.any { pl ->
      pl.profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10 ||
        pl.profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10 ||
        pl.profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10Plus
    }
  }

  // --- helpers ---------------------------------------------------------

  private fun resolveFilePath(uri: String): String = when {
    uri.startsWith("file://") -> uri.substring("file://".length)
    else -> uri
  }

  private fun selectVideoTrack(extractor: MediaExtractor): Int {
    for (i in 0 until extractor.trackCount) {
      val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: ""
      if (mime.startsWith("video/")) return i
    }
    throw InvalidSpecException("Source has no video track")
  }

  private fun hasAudioTrack(extractor: MediaExtractor): Boolean {
    for (i in 0 until extractor.trackCount) {
      val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: ""
      if (mime.startsWith("audio/")) return true
    }
    return false
  }

  private fun canonicalCodec(mime: String): String {
    val lower = mime.lowercase()
    return when (lower) {
      "video/avc" -> "h264"
      "video/hevc" -> "hevc"
      else -> lower.removePrefix("video/")
    }
  }

  private fun containerFromPath(path: String): String {
    val dot = path.lastIndexOf('.')
    if (dot < 0 || dot == path.length - 1) return ""
    return path.substring(dot + 1).lowercase()
  }

  private fun readFrameRate(format: MediaFormat): Double {
    if (!format.containsKey(MediaFormat.KEY_FRAME_RATE)) return 0.0
    // KEY_FRAME_RATE can be either Integer or Float depending on source.
    return try {
      format.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble()
    } catch (_: ClassCastException) {
      format.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble()
    }
  }

  private fun readBitRate(format: MediaFormat, retriever: MediaMetadataRetriever): Long {
    if (format.containsKey(MediaFormat.KEY_BIT_RATE)) {
      return format.getInteger(MediaFormat.KEY_BIT_RATE).toLong()
    }
    val meta = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)
    return meta?.toLongOrNull() ?: 0L
  }

  private fun readDurationSec(format: MediaFormat, retriever: MediaMetadataRetriever): Double {
    if (format.containsKey(MediaFormat.KEY_DURATION)) {
      return format.getLong(MediaFormat.KEY_DURATION) / 1_000_000.0
    }
    val ms = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
    return (ms ?: 0L) / 1000.0
  }

  private fun readRotation(format: MediaFormat, retriever: MediaMetadataRetriever): Int {
    if (format.containsKey(MediaFormat.KEY_ROTATION)) {
      val raw = format.getInteger(MediaFormat.KEY_ROTATION)
      return ((raw % 360) + 360) % 360
    }
    val meta = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
      ?.toIntOrNull() ?: 0
    return ((meta % 360) + 360) % 360
  }

  private fun readIsHDR(format: MediaFormat): Boolean {
    if (!format.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) return false
    // COLOR_TRANSFER constants exist since API 24. ST2084 = PQ, HLG = HLG.
    // Both live under the SMPTE/ITU HDR transfer-characteristic ids, matching
    // iOS AVDemuxer's HLG/PQ check.
    val transfer = format.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
    return transfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
      transfer == MediaFormat.COLOR_TRANSFER_HLG
  }

  private fun parseCreationDate(raw: String?): Instant? {
    if (raw.isNullOrEmpty()) return null
    // METADATA_KEY_DATE is formatted like "20260424T123456.000Z" for mp4/mov
    // authored on Android, or ISO 8601 for some content. Try both shapes.
    return try {
      Instant.parse(raw)
    } catch (_: Throwable) {
      try {
        DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss.SSSX")
          .parse(raw, Instant::from)
      } catch (_: Throwable) {
        try {
          DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmssX")
            .parse(raw, Instant::from)
        } catch (_: Throwable) {
          null
        }
      }
    }
  }

  // ISO 6709 parser — same shape as iOS AVDemuxer's. Accepts signed lat/lon
  // tokens at the start (e.g. "+48.8584+002.2945/"). An optional third
  // signed token encodes altitude in metres ("+48.8584+002.2945+520.000/");
  // when present it lands on `WGS84Coordinate.altitude`. Any further
  // trailing tokens (CRS) are ignored. Returns null on malformed input.
  private fun parseISO6709(raw: String?): WGS84Coordinate? {
    if (raw.isNullOrEmpty()) return null
    val s = raw
    var idx = 0
    val values = DoubleArray(2)
    for (i in 0..1) {
      if (idx >= s.length) return null
      val c = s[idx]
      if (c != '+' && c != '-') return null
      // Find the end of the numeric token: scan until next '+' or '-' or
      // '/' or end of string, not counting the sign at position `idx`.
      var end = idx + 1
      while (end < s.length && s[end] != '+' && s[end] != '-' && s[end] != '/') {
        end++
      }
      val token = s.substring(idx, end)
      val v = token.toDoubleOrNull() ?: return null
      values[i] = v
      idx = end
    }
    var altitude: Double? = null
    if (idx < s.length && (s[idx] == '+' || s[idx] == '-')) {
      var end = idx + 1
      while (end < s.length && s[end] != '+' && s[end] != '-' && s[end] != '/') {
        end++
      }
      altitude = s.substring(idx, end).toDoubleOrNull()
    }
    return WGS84Coordinate(
      latitude = values[0],
      longitude = values[1],
      altitude = altitude,
    )
  }

  private fun collectCustomMetadata(retriever: MediaMetadataRetriever): Map<String, String> {
    // Mirror iOS AVMetadataCommonKey* surface: the keys iOS emits to `custom`
    // are `title`, `artist`, `author`, `software`, `description`, etc.
    // MediaMetadataRetriever's key constants map roughly to the same set.
    val m = LinkedHashMap<String, String>()
    listOf(
      "title" to MediaMetadataRetriever.METADATA_KEY_TITLE,
      "artist" to MediaMetadataRetriever.METADATA_KEY_ARTIST,
      "author" to MediaMetadataRetriever.METADATA_KEY_AUTHOR,
      "composer" to MediaMetadataRetriever.METADATA_KEY_COMPOSER,
      "writer" to MediaMetadataRetriever.METADATA_KEY_WRITER,
      "genre" to MediaMetadataRetriever.METADATA_KEY_GENRE,
      "year" to MediaMetadataRetriever.METADATA_KEY_YEAR,
      "albumartist" to MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST,
      "album" to MediaMetadataRetriever.METADATA_KEY_ALBUM,
      "compilation" to MediaMetadataRetriever.METADATA_KEY_COMPILATION,
    ).forEach { (name, key) ->
      val value = retriever.extractMetadata(key)
      if (!value.isNullOrEmpty()) m[name] = value
    }
    return m
  }

  private fun applyRotationIfNeeded(
    bitmap: Bitmap,
    rotationDeg: Int,
    metaW: Int,
    metaH: Int,
  ): Bitmap {
    if (rotationDeg == 0) return bitmap
    val normalized = ((rotationDeg % 360) + 360) % 360
    if (normalized == 0) return bitmap
    // If the bitmap already matches the rotated orientation, skip rotating
    // again. For 90/270 the rotated dimensions swap, so compare against
    // swapped meta w/h in that case.
    val rotatedW = if (normalized == 90 || normalized == 270) metaH else metaW
    val rotatedH = if (normalized == 90 || normalized == 270) metaW else metaH
    if (bitmap.width == rotatedW && bitmap.height == rotatedH) {
      // Platform already rotated.
      return bitmap
    }
    val matrix = Matrix()
    matrix.postRotate(normalized.toFloat())
    return Bitmap.createBitmap(
      bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true,
    )
  }

  private fun resizeLongestSide(src: Bitmap, targetW: Double, targetH: Double): Bitmap {
    val hasW = targetW > 0
    val hasH = targetH > 0
    if (!hasW && !hasH) return src
    val srcW = src.width.toDouble()
    val srcH = src.height.toDouble()
    if (srcW <= 0 || srcH <= 0) return src
    val scale = when {
      hasW && hasH -> min(targetW / srcW, targetH / srcH)
      hasW -> targetW / srcW
      else -> targetH / srcH
    }
    if (scale >= 1.0) return src
    val outW = max(1.0, floor(srcW * scale)).toInt()
    val outH = max(1.0, floor(srcH * scale)).toInt()
    return Bitmap.createScaledBitmap(src, outW, outH, true)
  }
}
