///
/// RNVPFrameBytes.h
///
/// Nitro-free pixel-buffer byte-math for the FrameTarget/FrameSource contract
/// (#99). Kept in its own translation unit — free of any Nitro-generated
/// dependency — so the host XCTest harness (`yarn test:native`, which cannot
/// compile HybridFrameTarget/HybridFrameSource because of their Nitro base
/// classes) can exercise the stride/length logic directly against real
/// CVPixelBuffers.
///
/// The contract is format-driven: bytes-per-pixel is read off the buffer's
/// actual CoreVideo pixel format, not a hand-passed enum, so an 8-bit SDR
/// buffer (32BGRA, 4 bpp) and a 10-bit-capable HDR buffer (64RGBAHalf, 8 bpp)
/// share one code path. See `PixelFormat` in the Nitro spec.
///

#pragma once

#import <CoreVideo/CoreVideo.h>
#import <stddef.h>
#import <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Packed (no row padding) bytes-per-pixel for a CoreVideo pixel format.
/// Returns 0 for a format the compose pump does not handle — callers treat that
/// as "unsupported format", never as a zero-length buffer.
///   - kCVPixelFormatType_32BGRA        → 4
///   - kCVPixelFormatType_64RGBAHalf    → 8  (FP16 RGBA — the `rgbaFp16` HDR
///                                            worklet target, #99)
size_t RNVPFrameBytesPerPixel(OSType cvPixelFormat);

/// Expected packed byte length of one frame: `width * height * bytesPerPixel`.
/// Returns 0 when the buffer is NULL or its format is unsupported.
size_t RNVPFrameExpectedByteLength(CVPixelBufferRef pixelBuffer);

/// Copy `srcLen` packed bytes into `pixelBuffer`, handling any per-row stride
/// padding CoreVideo added. Locks/unlocks the buffer internally. Returns false
/// (a no-op) when the format is unsupported, `srcLen` does not match
/// `RNVPFrameExpectedByteLength`, or the base-address lock fails — the caller is
/// expected to have already validated length and to raise a typed error.
bool RNVPFrameWritePackedBytes(CVPixelBufferRef pixelBuffer,
                               const void *src,
                               size_t srcLen);

/// Allocate (via `malloc`) and return a packed copy of `pixelBuffer`'s pixels,
/// stripping any per-row stride padding, in the buffer's own format (4 bpp for
/// 8-bit, 8 bpp for FP16). Sets `*outLen` to the byte count. Returns NULL on a
/// NULL/unsupported buffer or lock failure. The caller owns the returned
/// pointer and must `free` it.
void *RNVPFrameCopyPackedBytes(CVPixelBufferRef pixelBuffer, size_t *outLen);

#ifdef __cplusplus
}
#endif
