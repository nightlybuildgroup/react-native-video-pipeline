///
/// HybridFrameTarget.mm — see HybridFrameTarget.h.
///

#import "HybridFrameTarget.h"
#import "MetalBlit.h"
#import "RNVPFrameBytes.h"

#import <Foundation/Foundation.h>

#include <cstring>
#include <stdexcept>

namespace margelo::nitro::videopipeline {

namespace {

void throwIfInvalid(bool invalidated) {
  if (invalidated) {
    throw std::runtime_error(
        "VideoPipeline.FrameTarget: InvalidSpec — this handle was "
        "invalidated when the enclosing drawFrame call returned. Each "
        "FrameTarget is valid only for the duration of the worklet "
        "invocation that received it; do not retain it across frames.");
  }
}

}  // namespace

uint64_t HybridFrameTarget::getUnstable_bufferAddr() {
  throwIfInvalid(invalidated_);
  if (pixelBuffer_ == nullptr) return 0;
  // The JS-visible unstable_bufferAddr is the IOSurface-backed base address.
  // We expose it read-only to consumers that want to read pixels (e.g.
  // Skia's MakeImageFromNativeBuffer); writes must go through writeBytes /
  // unstable_blitFromNativeTexture so lock/unlock stays balanced. Callers
  // never dereference this pointer directly from JS.
  return reinterpret_cast<uint64_t>(CVPixelBufferGetBaseAddress(pixelBuffer_));
}

double HybridFrameTarget::getWidth() {
  throwIfInvalid(invalidated_);
  if (pixelBuffer_ == nullptr) return 0.0;
  return static_cast<double>(CVPixelBufferGetWidth(pixelBuffer_));
}

double HybridFrameTarget::getHeight() {
  throwIfInvalid(invalidated_);
  if (pixelBuffer_ == nullptr) return 0.0;
  return static_cast<double>(CVPixelBufferGetHeight(pixelBuffer_));
}

PixelFormat HybridFrameTarget::getFormat() {
  throwIfInvalid(invalidated_);
  return format_;
}

void HybridFrameTarget::writeBytes(const std::shared_ptr<ArrayBuffer>& bytes) {
  throwIfInvalid(invalidated_);
  if (pixelBuffer_ == nullptr) {
    throw std::runtime_error(
        "VideoPipeline.FrameTarget.writeBytes: InvalidSpec — null buffer");
  }
  if (bytes == nullptr) {
    throw std::runtime_error(
        "VideoPipeline.FrameTarget.writeBytes: InvalidSpec — null bytes");
  }

  // Format-driven byte math (#99): 4 bytes/px for 8-bit (bgra8888/rgba8888),
  // 8 bytes/px for the FP16 HDR target (rgbaFp16). RNVPFrameBytes reads the
  // stride/length off the buffer's actual CoreVideo format so both share one
  // path; see RNVPFrameBytes.{h,mm} (also exercised directly by test:native).
  const size_t width = CVPixelBufferGetWidth(pixelBuffer_);
  const size_t height = CVPixelBufferGetHeight(pixelBuffer_);
  const size_t expected = RNVPFrameExpectedByteLength(pixelBuffer_);
  if (expected == 0) {
    throw std::runtime_error(
        "VideoPipeline.FrameTarget.writeBytes: InvalidSpec — unsupported pixel "
        "format");
  }
  const size_t bpp = expected / (width * height);
  const size_t provided = bytes->size();
  if (provided != expected) {
    char msg[256];
    std::snprintf(
        msg, sizeof(msg),
        "VideoPipeline.FrameTarget.writeBytes: InvalidSpec — byte length "
        "%zu does not match width*height*%zu = %zu*%zu*%zu = %zu",
        provided, bpp, width, height, bpp, expected);
    throw std::runtime_error(msg);
  }

  if (!RNVPFrameWritePackedBytes(pixelBuffer_, bytes->data(), provided)) {
    throw std::runtime_error(
        "VideoPipeline.FrameTarget.writeBytes: IOError — "
        "CVPixelBufferLockBaseAddress failed");
  }
}

void HybridFrameTarget::unstable_blitFromNativeTexture(uint64_t mtlTexturePtr) {
  throwIfInvalid(invalidated_);
  if (pixelBuffer_ == nullptr) {
    throw std::runtime_error(
        "VideoPipeline.FrameTarget.unstable_blitFromNativeTexture: "
        "InvalidSpec — null buffer");
  }

  NSError* error = nil;
  const uintptr_t texPtr = static_cast<uintptr_t>(mtlTexturePtr);
  const BOOL ok =
      [RNVPMetalBlit blitFromMetalTexturePtr:texPtr
                                toPixelBuffer:pixelBuffer_
                                        error:&error];
  if (!ok) {
    const char* desc = error.localizedDescription.UTF8String ?: "(nil)";
    throw std::runtime_error(
        std::string("VideoPipeline.FrameTarget.unstable_blitFromNativeTexture: ") +
        desc);
  }
}

}  // namespace margelo::nitro::videopipeline
