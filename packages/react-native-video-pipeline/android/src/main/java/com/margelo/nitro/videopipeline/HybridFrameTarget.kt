///
/// HybridFrameTarget.kt
///
/// Android subclass of the nitrogen-generated `HybridFrameTargetSpec`. The
/// per-frame write surface that the JS Skia worklet fills via
/// `target.writeBytes(arrayBuffer)`. The pump that constructed the wrapper
/// reads the underlying ByteBuffer after the JS callback returns and
/// uploads it to the encoder's input surface (see `VideoEncoder.writeRgbaFrame`).
///
/// Lifetime — one instance per output frame:
///   1. Pump allocates a direct `ByteBuffer` of `width * height * 4`,
///      constructs this wrapper, hands the instance to the JS callback.
///   2. Worklet calls `writeBytes(arrayBuffer)` — we copy the bytes into
///      the underlying ByteBuffer.
///   3. Pump calls `invalidate()`; further JS calls throw InvalidSpec.
///   4. Pump uploads the ByteBuffer to GL + draws to the encoder surface.
///
/// `blitFromNativeTexture` is the iOS Metal fast path; on Android we don't
/// have an equivalent in this slice (Skia GPU export to MediaCodec needs
/// AHardwareBuffer + ImageWriter plumbing — separate task), so the method
/// throws and `drawWithSkia` falls back to its CPU-readback path.
///

package com.margelo.nitro.videopipeline

import com.margelo.nitro.core.ArrayBuffer
import java.nio.ByteBuffer

internal class HybridFrameTarget(
  private val backing: ByteBuffer,
  private val widthPx: Int,
  private val heightPx: Int,
  private val pixelFormat: PixelFormat,
) : HybridFrameTargetSpec() {
  @Volatile
  private var invalidated = false

  override val bufferAddr: Long
    get() {
      throwIfInvalid()
      // The address is unused by drawWithSkia's writeBytes path on Android;
      // expose 0 instead of leaking the JNI direct-buffer address.
      return 0L
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

  override fun writeBytes(bytes: ArrayBuffer) {
    throwIfInvalid()
    val expected = widthPx * heightPx * 4
    val src = bytes.getBuffer(false)
    val srcRemaining = src.remaining()
    require(srcRemaining == expected) {
      "VideoPipeline.FrameTarget.writeBytes: InvalidSpec — byte length " +
        "$srcRemaining does not match width*height*4 = $widthPx*$heightPx*4 " +
        "= $expected"
    }
    backing.position(0)
    backing.put(src)
    backing.position(0)
  }

  override fun blitFromNativeTexture(mtlTexturePtr: Long) {
    throwIfInvalid()
    throw UnsupportedOperationException(
      "VideoPipeline.FrameTarget.blitFromNativeTexture: GPU fast path is " +
        "iOS-only in this slice. Android falls back via drawWithSkia's CPU " +
        "readback (writeBytes); this method should not be reached."
    )
  }

  /// Mark the wrapper stale; the pump owns the ByteBuffer and may recycle
  /// it for the next frame after this returns. Any later JS call throws.
  fun invalidate() {
    invalidated = true
  }

  /// Pump-side accessor — read-only view onto the bytes the worklet wrote.
  fun pixelsForEncoder(): ByteBuffer {
    backing.position(0)
    return backing
  }

  private fun throwIfInvalid() {
    if (invalidated) {
      throw IllegalStateException(
        "VideoPipeline.FrameTarget: InvalidSpec — this handle was " +
          "invalidated when the enclosing drawFrame call returned."
      )
    }
  }
}
