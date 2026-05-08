///
/// HybridFrameSource.kt — Android subclass of the nitrogen-generated
/// `HybridFrameSourceSpec`. Read-only view onto the current decoded source
/// frame. The pump owns the underlying `AHardwareBuffer` (acquired from the
/// decoder's ImageReader) and recycles it after the JS callback returns.
///
/// `bufferAddr` returns the `AHardwareBuffer*` pointer cast to a `Long` —
/// the Skia path: `Skia.Image.MakeImageFromNativeBuffer(addr)` reads the
/// buffer's GL backing directly, no readback. Same `bigint` shape as the
/// iOS `CVPixelBufferRef` path.
///
/// `readBytes()` is a CPU fallback for paths that aren't Skia (e.g. pixel
/// hashing in tests). It pulls the YUV/RGBA out via the underlying decoder
/// `Image.Plane`s — but the pump no longer wires that path; we return an
/// `UnsupportedOperationException` until a consumer needs it again.
///

package com.margelo.nitro.videopipeline

import com.margelo.nitro.core.ArrayBuffer

internal class HybridFrameSource(
  private val hardwareBufferPtr: Long,
  private val widthPx: Int,
  private val heightPx: Int,
  private val pixelFormat: PixelFormat,
) : HybridFrameSourceSpec() {
  @Volatile
  private var invalidated = false

  override val bufferAddr: Long
    get() {
      throwIfInvalid()
      return hardwareBufferPtr
    }

  override val width: Double
    get() {
      throwIfInvalid()
      return widthPx.toDouble()
    }

  override val height: Double
    get() {
      throwIfInvalid()
      return heightPx.toDouble()
    }

  override val format: PixelFormat
    get() {
      throwIfInvalid()
      return pixelFormat
    }

  override fun readBytes(): ArrayBuffer {
    throwIfInvalid()
    throw UnsupportedOperationException(
      "VideoPipeline.FrameSource.readBytes: AHardwareBuffer-backed sources " +
        "do not support CPU readback. Use Skia.Image.MakeImageFromNativeBuffer(bufferAddr) instead."
    )
  }

  fun invalidate() {
    invalidated = true
  }

  private fun throwIfInvalid() {
    if (invalidated) {
      throw IllegalStateException(
        "VideoPipeline.FrameSource: InvalidSpec — this handle was " +
          "invalidated when the enclosing drawFrame call returned."
      )
    }
  }
}
