///
/// HybridVideoPipeline.hpp
///
/// Concrete C++ hybrid object used by the Nitro autolinker. Declaration only —
/// the iOS stubs live in `ios/VideoPipeline.mm` (T016); Android will provide
/// its own implementation in T040+. Methods are intentionally left unimplemented
/// at this layer so every subsequent platform task can fill them in one at a
/// time without touching the shared spec.
///

#pragma once

#include "HybridVideoPipelineSpec.hpp"

namespace margelo::nitro::videopipeline {

class HybridVideoPipeline : public HybridVideoPipelineSpec {
public:
  HybridVideoPipeline() : HybridObject(TAG) {}
  ~HybridVideoPipeline() override = default;

  // Probe — see prd.md §8.
  std::shared_ptr<Promise<VideoInfo>> info(const std::string& uri) override;
  std::shared_ptr<Promise<std::string>> thumbnail(const std::string& uri,
                                                  const ThumbnailOptions& options) override;
  std::shared_ptr<Promise<EncoderCaps>> capabilities() override;

  // Auto-routed render — see prd.md §9.
  std::shared_ptr<Promise<void>> render(
      const VideoSpec& spec,
      const std::string& renderToken,
      const std::optional<std::function<void(const Progress&)>>& onProgress) override;
  void cancelRender(const std::string& renderToken) override;
  void finishRender(const std::string& renderToken) override;

  // Convenience wrappers — see prd.md §8/§9.
  std::shared_ptr<Promise<void>> trim(
      const std::string& uri,
      const std::string& outPath,
      double startSec,
      double durationSec,
      const std::optional<ClipTransform>& transform,
      const std::string& renderToken) override;
  std::shared_ptr<Promise<void>> flip(
      const std::string& uri,
      const std::string& outPath,
      FlipAxis axis,
      const std::string& renderToken) override;
  std::shared_ptr<Promise<void>> stamp(
      const std::string& uri,
      const std::string& outPath,
      const std::optional<std::variant<ImageOverlay, TextOverlay>>& watermark,
      const std::optional<MetadataSpec>& metadata,
      const std::string& renderToken) override;

  // Compose path — see prd.md §9 routing rules. The worklet (or plain JS
  // callback) runs per frame with a live FrameTarget HybridObject; writes
  // via `writeBytes` memcpy into the encoder's IOSurface-backed buffer.
  std::shared_ptr<Promise<void>> renderCompose(
      const VideoSpec& spec,
      const std::string& renderToken,
      const std::function<std::shared_ptr<Promise<bool>>(
          const std::shared_ptr<HybridFrameTargetSpec>&,
          const std::optional<std::shared_ptr<HybridFrameSourceSpec>>&,
          double, double)>& drawFrame,
      const std::optional<std::function<void(const Progress&)>>& onProgress)
      override;
};

} // namespace margelo::nitro::videopipeline
