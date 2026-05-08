///
/// HybridFrameSource.h — concrete iOS subclass of the Nitro-generated
/// `HybridFrameSourceSpec`. Read-only view onto the current source frame
/// (compose-on-clip path); the worklet typically passes
/// `bufferAddr` to `Skia.Image.MakeImageFromNativeBuffer` to draw the
/// source image before laying its own work on top.
///
/// Lifetime — one instance per output frame:
///   1. Native pump pulls a decoded CVPixelBuffer from the AVAssetReader,
///      constructs this wrapper, hands the shared_ptr to the worklet.
///   2. Worklet reads `bufferAddr` (and width/height/format).
///   3. Native pump calls `invalidate` after the worklet returns. Any later
///      JS-side method call throws `InvalidSpec` so a stale handle cannot
///      reach into a recycled buffer.
///

#pragma once

#import <CoreVideo/CoreVideo.h>

#include "HybridFrameSourceSpec.hpp"
#include "PixelFormat.hpp"

namespace margelo::nitro::videopipeline {

class HybridFrameSource : public HybridFrameSourceSpec {
 public:
  /// Holds a non-owning reference to @c pixelBuffer. The pump that constructed
  /// this wrapper owns the buffer's lifetime — it must outlive the
  /// drawFrame callback.
  HybridFrameSource(CVPixelBufferRef pixelBuffer, PixelFormat format)
      : HybridObject(TAG), pixelBuffer_(pixelBuffer), format_(format) {}

  // Properties
  uint64_t getBufferAddr() override;
  double getWidth() override;
  double getHeight() override;
  PixelFormat getFormat() override;

  // Methods
  std::shared_ptr<ArrayBuffer> readBytes() override;

  /// Mark the wrapper as stale; further calls from JS throw InvalidSpec.
  void invalidate() { invalidated_ = true; }

 private:
  CVPixelBufferRef pixelBuffer_;  // non-owning; lifetime owned by the pump
  PixelFormat format_;
  bool invalidated_ = false;
};

}  // namespace margelo::nitro::videopipeline
