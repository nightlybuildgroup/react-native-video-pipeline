///
/// HybridFrameSource.mm — see HybridFrameSource.h.
///

#import "HybridFrameSource.h"
#import "RNVPFrameBytes.h"

#include <cstdlib>
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

uint64_t HybridFrameSource::getUnstable_bufferAddr() {
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
  // Format-driven (#99): returns packed bytes in the buffer's own format —
  // width*height*4 for 8-bit (bgra8888/rgba8888), width*height*8 for the FP16
  // HDR source (rgbaFp16). RNVPFrameBytes strips CoreVideo row padding.
  size_t len = 0;
  void* packed = RNVPFrameCopyPackedBytes(pixelBuffer_, &len);
  if (packed == nullptr) {
    throw std::runtime_error(
        "VideoPipeline.FrameSource.readBytes: IOError — unsupported pixel "
        "format or CVPixelBufferLockBaseAddress failed");
  }
  uint8_t* dst = static_cast<uint8_t*>(packed);
  return ArrayBuffer::wrap(dst, len, [dst]() { std::free(dst); });
}

}  // namespace margelo::nitro::videopipeline
