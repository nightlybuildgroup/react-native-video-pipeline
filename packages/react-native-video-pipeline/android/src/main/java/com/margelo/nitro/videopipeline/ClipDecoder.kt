///
/// ClipDecoder.kt
///
/// MediaExtractor + MediaCodec decoder pair that emits decoded frames into an
/// `ImageReader`'s Surface. Each `awaitNextFrame()` returns the latest
/// decoded `Image`, from which the caller pulls a `HardwareBuffer` and hands
/// the underlying `AHardwareBuffer*` to Skia as a zero-copy SkImage source.
///
/// The Image is owned by the ImageReader pool; the `HardwareBuffer` returned
/// by `image.getHardwareBuffer()` carries its own ref on the underlying
/// AHardwareBuffer so we can safely `image.close()` immediately and let the
/// pool refill while Skia (and our pump) still hold a ref via the Java
/// HardwareBuffer. The pump closes the HardwareBuffer after the JS callback
/// returns (and thus after Skia disposed its SkImage), which drops the last
/// ref and lets ImageReader recycle the slot.
///
/// API 26+ — `getHardwareBuffer()` was added in O. Lower API gating belongs
/// at the compose-pump level.
///

package com.margelo.nitro.videopipeline

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.view.Surface
import androidx.annotation.RequiresApi
import java.io.File

@RequiresApi(Build.VERSION_CODES.O)
internal class ClipDecoder private constructor(
  private val extractor: MediaExtractor,
  private val codec: MediaCodec,
  val width: Int,
  val height: Int,
  val durationUs: Long,
  val nbFrames: Int,
  private val imageReader: ImageReader,
) {
  private val bufferInfo = MediaCodec.BufferInfo()
  private var inputDone = false
  private var outputDone = false

  /// Pull the next decoded frame onto the ImageReader and return its `Image`.
  /// Caller owns the Image + must call `Image.close()` after extracting the
  /// HardwareBuffer (the buffer's own ref keeps the underlying AHardwareBuffer
  /// alive). Returns `null` at end-of-stream; populates `outPtsUs[0]` with
  /// the presentation timestamp on success.
  fun awaitNextFrame(outPtsUs: LongArray): Image? {
    if (outputDone) return null
    while (true) {
      // Feed input until we either signaled EOS or got an output sample.
      if (!inputDone) {
        val inIdx = codec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
        if (inIdx >= 0) {
          val buf = codec.getInputBuffer(inIdx)
            ?: error("decoder.getInputBuffer($inIdx) returned null")
          val size = extractor.readSampleData(buf, 0)
          if (size < 0) {
            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            inputDone = true
          } else {
            val pts = extractor.sampleTime
            codec.queueInputBuffer(inIdx, 0, size, pts, 0)
            extractor.advance()
          }
        }
      }

      val outIdx = codec.dequeueOutputBuffer(bufferInfo, DEQUEUE_TIMEOUT_US)
      if (outIdx == MediaCodec.INFO_TRY_AGAIN_LATER) continue
      if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) continue
      if (outIdx < 0) continue

      val isEos = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
      val hasFrame = bufferInfo.size > 0 && !isEos
      // releaseOutputBuffer(true) forwards the buffer to our Surface, which
      // wakes the ImageReader. The ImageReader fills its slot async; we poll
      // until acquireNextImage returns it (typically within a handful of ms).
      codec.releaseOutputBuffer(outIdx, hasFrame)
      if (hasFrame) {
        outPtsUs[0] = bufferInfo.presentationTimeUs
        var attempts = 0
        while (attempts < ACQUIRE_RETRY_LIMIT) {
          val image = imageReader.acquireNextImage()
          if (image != null) return image
          // Image not yet handed off from the codec to ImageReader; spin
          // briefly. In practice this fires once or not at all.
          Thread.sleep(1)
          attempts++
        }
        error("ClipDecoder: ImageReader.acquireNextImage timed out")
      }
      if (isEos) {
        outputDone = true
        return null
      }
    }
  }

  fun close() {
    try { codec.stop() } catch (_: Throwable) {}
    try { codec.release() } catch (_: Throwable) {}
    try { extractor.release() } catch (_: Throwable) {}
    try { imageReader.close() } catch (_: Throwable) {}
  }

  companion object {
    private const val DEQUEUE_TIMEOUT_US = 10_000L
    private const val ACQUIRE_RETRY_LIMIT = 100

    @RequiresApi(Build.VERSION_CODES.O)
    fun open(uri: String): ClipDecoder {
      // Strip file:// prefix; MediaExtractor wants a real path.
      val path = if (uri.startsWith("file://")) uri.removePrefix("file://") else uri
      require(File(path).exists()) { "ClipDecoder: source not found at $path" }

      val extractor = MediaExtractor()
      extractor.setDataSource(path)
      var videoTrack = -1
      var format: MediaFormat? = null
      for (i in 0 until extractor.trackCount) {
        val f = extractor.getTrackFormat(i)
        val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
        if (mime.startsWith("video/")) {
          videoTrack = i
          format = f
          break
        }
      }
      require(videoTrack >= 0 && format != null) {
        "ClipDecoder: source has no video track"
      }
      extractor.selectTrack(videoTrack)

      val width = format.getInteger(MediaFormat.KEY_WIDTH)
      val height = format.getInteger(MediaFormat.KEY_HEIGHT)
      val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
        format.getLong(MediaFormat.KEY_DURATION)
      } else {
        0L
      }
      val frameRate = if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
        format.getInteger(MediaFormat.KEY_FRAME_RATE)
      } else {
        30
      }
      val nbFrames =
        ((durationUs / 1_000_000.0) * frameRate.toDouble()).toInt().coerceAtLeast(0)

      // ImageFormat.PRIVATE = let the producer (decoder) and consumer (Skia
      // GL via AHardwareBuffer) negotiate the underlying YUV/RGBA format.
      // USAGE_GPU_SAMPLED_IMAGE tells the kernel the buffer will be sampled
      // by GL — required for Skia's eglCreateImageKHR on 29+. On 26-28 we
      // fall back to the no-usage constructor; Skia's Adreno/Mali stacks
      // accept those buffers anyway.
      val reader = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        ImageReader.newInstance(
          width,
          height,
          ImageFormat.PRIVATE,
          /* maxImages = */ 4,
          HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
        )
      } else {
        ImageReader.newInstance(width, height, ImageFormat.PRIVATE, 4)
      }
      val outputSurface = reader.surface

      val mime = format.getString(MediaFormat.KEY_MIME)!!
      val codec = MediaCodec.createDecoderByType(mime)
      codec.configure(format, outputSurface, null, 0)
      codec.start()

      return ClipDecoder(
        extractor = extractor,
        codec = codec,
        width = width,
        height = height,
        durationUs = durationUs,
        nbFrames = nbFrames,
        imageReader = reader,
      )
    }
  }
}
