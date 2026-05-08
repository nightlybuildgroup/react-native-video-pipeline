///
/// HybridFrameSource.mm — see HybridFrameSource.h.
///

#import "HybridFrameSource.h"

#include <stdexcept>

namespace margelo::nitro::videopipeline {

namespace {

void throwIfInvalid(bool invalidated) {
  if (invalidated) {
    throw std::runtime_error(
        "VideoPipeline.FrameSource: InvalidSpec — this handle was "
        "invalidated when the enclosing drawFrame call returned. Each "
        "FrameSource is valid only for the duration of the worklet "
        "invocation that received it; do not retain it across frames.");
  }
}

}  // namespace

uint64_t HybridFrameSource::getBufferAddr() {
  throwIfInvalid(invalidated_);
  // Skia's `MakeImageFromNativeBuffer` reinterprets this bigint as a
  // CVPixelBufferRef and reads format/dimensions off the wrapper itself —
  // not the raw pixel base address. Returning the base address makes Skia
  // see "unknown pixel format" because the metadata isn't there.
  return reinterpret_cast<uint64_t>(pixelBuffer_);
}

double HybridFrameSource::getWidth() {
  throwIfInvalid(invalidated_);
  if (pixelBuffer_ == nullptr) return 0.0;
  return static_cast<double>(CVPixelBufferGetWidth(pixelBuffer_));
}

double HybridFrameSource::getHeight() {
  throwIfInvalid(invalidated_);
  if (pixelBuffer_ == nullptr) return 0.0;
  return static_cast<double>(CVPixelBufferGetHeight(pixelBuffer_));
}

PixelFormat HybridFrameSource::getFormat() {
  throwIfInvalid(invalidated_);
  return format_;
}

std::shared_ptr<ArrayBuffer> HybridFrameSource::readBytes() {
  throwIfInvalid(invalidated_);
  if (pixelBuffer_ == nullptr) {
    throw std::runtime_error(
        "VideoPipeline.FrameSource.readBytes: InvalidSpec — null buffer");
  }
  const size_t width = CVPixelBufferGetWidth(pixelBuffer_);
  const size_t height = CVPixelBufferGetHeight(pixelBuffer_);
  const size_t expected = width * height * 4;

  CVReturn cv = CVPixelBufferLockBaseAddress(pixelBuffer_,
                                              kCVPixelBufferLock_ReadOnly);
  if (cv != kCVReturnSuccess) {
    throw std::runtime_error(
        "VideoPipeline.FrameSource.readBytes: IOError — "
        "CVPixelBufferLockBaseAddress failed");
  }
  const uint8_t* src =
      static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(pixelBuffer_));
  const size_t srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer_);
  const size_t dstRowBytes = width * 4;

  uint8_t* dst = new uint8_t[expected];
  if (srcRowBytes == dstRowBytes) {
    std::memcpy(dst, src, expected);
  } else {
    for (size_t y = 0; y < height; ++y) {
      std::memcpy(dst + y * dstRowBytes, src + y * srcRowBytes, dstRowBytes);
    }
  }
  CVPixelBufferUnlockBaseAddress(pixelBuffer_, kCVPixelBufferLock_ReadOnly);

  return ArrayBuffer::wrap(dst, expected, [dst]() { delete[] dst; });
}

}  // namespace margelo::nitro::videopipeline
