///
/// RNVPFrameBytes.mm — see RNVPFrameBytes.h.
///

#import "RNVPFrameBytes.h"

#import <cstdlib>
#import <cstring>

size_t RNVPFrameBytesPerPixel(OSType cvPixelFormat) {
  switch (cvPixelFormat) {
    case kCVPixelFormatType_32BGRA:
    case kCVPixelFormatType_32RGBA:
      return 4;  // 8-bit SDR — 'bgra8888' / 'rgba8888'
    case kCVPixelFormatType_64RGBAHalf:
      return 8;  // FP16 RGBA — 'rgbaFp16' HDR worklet target (#99)
    default:
      return 0;  // unsupported by the compose pump
  }
}

size_t RNVPFrameExpectedByteLength(CVPixelBufferRef pixelBuffer) {
  if (pixelBuffer == NULL) return 0;
  const size_t bpp =
      RNVPFrameBytesPerPixel(CVPixelBufferGetPixelFormatType(pixelBuffer));
  if (bpp == 0) return 0;
  const size_t width = CVPixelBufferGetWidth(pixelBuffer);
  const size_t height = CVPixelBufferGetHeight(pixelBuffer);
  return width * height * bpp;
}

bool RNVPFrameWritePackedBytes(CVPixelBufferRef pixelBuffer,
                               const void *src,
                               size_t srcLen) {
  if (pixelBuffer == NULL || src == NULL) return false;
  const size_t expected = RNVPFrameExpectedByteLength(pixelBuffer);
  if (expected == 0 || srcLen != expected) return false;

  if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) {
    return false;
  }
  uint8_t *dst = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(pixelBuffer));
  const size_t width = CVPixelBufferGetWidth(pixelBuffer);
  const size_t bpp =
      RNVPFrameBytesPerPixel(CVPixelBufferGetPixelFormatType(pixelBuffer));
  const size_t srcRowBytes = width * bpp;
  const size_t dstRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);
  const uint8_t *s = static_cast<const uint8_t *>(src);

  if (dstRowBytes == srcRowBytes) {
    std::memcpy(dst, s, expected);
  } else {
    // CoreVideo added row padding: copy row-by-row so the packed source lands
    // at the right offset for every row instead of scribbling across the gaps.
    const size_t height = CVPixelBufferGetHeight(pixelBuffer);
    for (size_t y = 0; y < height; ++y) {
      std::memcpy(dst + y * dstRowBytes, s + y * srcRowBytes, srcRowBytes);
    }
  }
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
  return true;
}

void *RNVPFrameCopyPackedBytes(CVPixelBufferRef pixelBuffer, size_t *outLen) {
  if (outLen != NULL) *outLen = 0;
  if (pixelBuffer == NULL) return NULL;
  const size_t expected = RNVPFrameExpectedByteLength(pixelBuffer);
  if (expected == 0) return NULL;

  if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) !=
      kCVReturnSuccess) {
    return NULL;
  }
  const uint8_t *src =
      static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(pixelBuffer));
  const size_t width = CVPixelBufferGetWidth(pixelBuffer);
  const size_t height = CVPixelBufferGetHeight(pixelBuffer);
  const size_t bpp =
      RNVPFrameBytesPerPixel(CVPixelBufferGetPixelFormatType(pixelBuffer));
  const size_t dstRowBytes = width * bpp;
  const size_t srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);

  uint8_t *dst = static_cast<uint8_t *>(std::malloc(expected));
  if (dst == NULL) {
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    return NULL;
  }
  if (srcRowBytes == dstRowBytes) {
    std::memcpy(dst, src, expected);
  } else {
    for (size_t y = 0; y < height; ++y) {
      std::memcpy(dst + y * dstRowBytes, src + y * srcRowBytes, dstRowBytes);
    }
  }
  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  if (outLen != NULL) *outLen = expected;
  return dst;
}
