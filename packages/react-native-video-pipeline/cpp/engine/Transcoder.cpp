///
/// Transcoder.cpp — see Transcoder.hpp for the contract.
///

#include "engine/Transcoder.hpp"

#include <cmath>

namespace margelo::nitro::videopipeline {

std::optional<std::string> describeTranscodeRejection(
    const TranscodeTarget& target,
    const std::optional<TranscodeSourceProbe>& source) {
  if (target.width <= 0) {
    return "transcode: output.width must be a positive integer";
  }
  if (target.height <= 0) {
    return "transcode: output.height must be a positive integer";
  }
  if (!std::isfinite(target.fps) || target.fps <= 0.0) {
    return "transcode: output.fps must be a positive finite number";
  }
  if (target.bitrate.has_value() && *target.bitrate <= 0) {
    return "transcode: output.bitrate must be > 0 when provided";
  }
  if (target.rotate.has_value()) {
    const int r = *target.rotate;
    if (r != 0 && r != 90 && r != 180 && r != 270) {
      return "transcode: transform.rotate must be one of {0, 90, 180, 270}";
    }
  }
  if (target.crop.has_value()) {
    const auto& c = *target.crop;
    if (!std::isfinite(c.x) || c.x < 0.0 ||
        !std::isfinite(c.y) || c.y < 0.0 ||
        !std::isfinite(c.width) || c.width <= 0.0 ||
        !std::isfinite(c.height) || c.height <= 0.0) {
      return "transcode: transform.crop must be finite with non-negative "
             "origin and positive width/height";
    }
    if (source.has_value()) {
      // One-pixel tolerance absorbs the occasional sub-pixel float error in
      // upstream callers that compute crop from normalised coordinates.
      if (c.x + c.width > static_cast<double>(source->width) + 1.0 ||
          c.y + c.height > static_cast<double>(source->height) + 1.0) {
        return "transcode: transform.crop extends beyond source bounds";
      }
    }
  }
  return std::nullopt;
}

} // namespace margelo::nitro::videopipeline
