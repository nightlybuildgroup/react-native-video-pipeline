///
/// HybridFrameTarget.mm — see HybridFrameTarget.h.
///

#import "HybridFrameTarget.h"
#import "MetalBlit.h"

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

  const size_t width = CVPixelBufferGetWidth(pixelBuffer_);
  const size_t height = CVPixelBufferGetHeight(pixelBuffer_);
  const size_t expected = width * height * 4;
  const size_t provided = bytes->size();
  if (provided != expected) {
    char msg[256];
    std::snprintf(
        msg, sizeof(msg),
        "VideoPipeline.FrameTarget.writeBytes: InvalidSpec — byte length "
        "%zu does not match width*height*4 = %zu*%zu*4 = %zu",
        provided, width, height, expected);
    throw std::runtime_error(msg);
  }

  CVReturn cv = CVPixelBufferLockBaseAddress(pixelBuffer_, 0);
  if (cv != kCVReturnSuccess) {
    throw std::runtime_error(
        "VideoPipeline.FrameTarget.writeBytes: IOError — "
        "CVPixelBufferLockBaseAddress failed");
  }

  uint8_t* dst = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixelBuffer_));
  const size_t dstRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer_);
  const size_t srcRowBytes = width * 4;
  const uint8_t* src = bytes->data();

  if (dstRowBytes == srcRowBytes) {
    // Happy path: packed source matches packed destination. One memcpy.
    std::memcpy(dst, src, expected);
  } else {
    // CoreVideo added row padding; copy row-by-row so we don't scribble
    // over the inter-row gaps (a single memcpy would land the second row's
    // data at the wrong offset for all subsequent rows).
    for (size_t y = 0; y < height; ++y) {
      std::memcpy(dst + y * dstRowBytes, src + y * srcRowBytes, srcRowBytes);
    }
  }

  CVPixelBufferUnlockBaseAddress(pixelBuffer_, 0);
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
