package com.margelo.nitro.videopipeline

/// Packed bytes-per-pixel for a worklet FrameTarget/FrameSource format (#99),
/// the Android counterpart to iOS `RNVPFrameBytesPerPixel`. Exhaustive `when`
/// (no `else`) so a future `PixelFormat` member forces a compile error here
/// instead of silently defaulting to 4.
///   - BGRA8888 / RGBA8888 → 4 (8-bit SDR)
///   - RGBAFP16            → 8 (half-float RGBA — the `rgbaFp16` HDR target)
internal fun bytesPerPixel(format: PixelFormat): Int =
  when (format) {
    PixelFormat.BGRA8888, PixelFormat.RGBA8888 -> 4
    PixelFormat.RGBAFP16 -> 8
  }
