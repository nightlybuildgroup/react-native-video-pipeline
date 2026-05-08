///
/// HybridFrameTarget.h — concrete iOS subclass of the Nitro-generated
/// `HybridFrameTargetSpec`. Wraps a per-frame `CVPixelBuffer` and exposes
/// the write paths the worklet calls: `writeBytes` (CPU memcpy into the
/// locked base address) and `blitFromNativeTexture` (iOS GPU fast path via
/// `RNVPMetalBlit` from T053b).
///
/// Lifecycle — one instance per frame:
///   1. Native pump allocates an IOSurface-backed CVPixelBuffer, constructs
///      this wrapper, hands the shared_ptr to the worklet callback.
///   2. Worklet writes via `writeBytes` or `blitFromNativeTexture`.
///   3. Native pump calls `invalidate` after the worklet returns — any
///      further JS-side method call throws `InvalidSpec` so a stale
///      reference can't corrupt a later frame's buffer.
///

#pragma once

#import <CoreVideo/CoreVideo.h>

#include "HybridFrameTargetSpec.hpp"
#include "PixelFormat.hpp"

namespace margelo::nitro::videopipeline {

class HybridFrameTarget : public HybridFrameTargetSpec {
 public:
  /// Holds a non-owning reference to @c pixelBuffer. The pump that constructed
  /// this wrapper owns the buffer's lifetime — it must outlive the
  /// drawFrame callback. After the callback returns the pump calls
  /// @c invalidate() and the JS-side handle becomes inert; if the JS side
  /// retained the wrapper past that point, every method throws InvalidSpec
  /// before the (now-stale) buffer pointer is touched.
  HybridFrameTarget(CVPixelBufferRef pixelBuffer, PixelFormat format)
      : HybridObject(TAG), pixelBuffer_(pixelBuffer), format_(format) {}

  // Properties
  uint64_t getBufferAddr() override;
  double getWidth() override;
  double getHeight() override;
  PixelFormat getFormat() override;

  // Methods
  void writeBytes(const std::shared_ptr<ArrayBuffer>& bytes) override;
  void blitFromNativeTexture(uint64_t mtlTexturePtr) override;

  /// Mark the wrapper as stale; further calls from JS throw InvalidSpec.
  void invalidate() { invalidated_ = true; }

 private:
  CVPixelBufferRef pixelBuffer_;  // non-owning; lifetime owned by the pump
  PixelFormat format_;
  bool invalidated_ = false;
};

}  // namespace margelo::nitro::videopipeline
