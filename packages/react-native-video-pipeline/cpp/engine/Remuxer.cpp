///
/// Remuxer.cpp — see Remuxer.hpp for the contract.
///

#include "engine/Remuxer.hpp"

#include <cmath>
#include <cstddef>

namespace margelo::nitro::videopipeline {

namespace {

// Shared tolerance for float-based time comparisons. One millisecond is
// comfortably smaller than a frame at any realistic framerate (e.g. 1/240s ≈
// 4.2 ms at 240 fps) so "contiguous" here still means "no perceptible gap".
constexpr double kSecondsTolerance = 1e-3;

} // namespace

std::optional<std::string> describeTrimRejection(
    const TrimSpec& spec, std::optional<double> sourceDurationSec) {
  if (!std::isfinite(spec.startSec) || spec.startSec < 0.0) {
    return "trim: startSec must be a non-negative finite number";
  }
  if (!std::isfinite(spec.durationSec) || spec.durationSec <= 0.0) {
    return "trim: durationSec must be a positive finite number";
  }
  if (sourceDurationSec.has_value()) {
    // One-millisecond tolerance keeps a caller asking for "the last second
    // of a one-second file" — where both bounds round-trip through doubles
    // — from tripping on sub-frame float error.
    if (spec.startSec + spec.durationSec >
        *sourceDurationSec + kSecondsTolerance) {
      return "trim: startSec + durationSec exceeds source duration";
    }
  }
  return std::nullopt;
}

std::optional<std::string> describeConcatRejection(
    const std::vector<ConcatClipSpec>& clips) {
  if (clips.empty()) {
    return "concat: clips must be non-empty";
  }
  double cumulativeDuration = 0.0;
  for (std::size_t i = 0; i < clips.size(); ++i) {
    const auto& c = clips[i];
    if (!std::isfinite(c.sourceStart) || c.sourceStart < 0.0) {
      return "concat: clip[" + std::to_string(i) +
             "].sourceStart must be a non-negative finite number";
    }
    if (!std::isfinite(c.sourceDuration) || c.sourceDuration <= 0.0) {
      return "concat: clip[" + std::to_string(i) +
             "].sourceDuration must be a positive finite number";
    }
    if (!std::isfinite(c.outputStart) || c.outputStart < 0.0) {
      return "concat: clip[" + std::to_string(i) +
             "].outputStart must be a non-negative finite number";
    }
    // Contiguous-timeline requirement — v0.1 passthrough concat has no way
    // to insert black frames for gaps or to blend overlapping ranges; those
    // land on the transcode path in later tasks.
    if (std::fabs(c.outputStart - cumulativeDuration) > kSecondsTolerance) {
      return "concat: clip[" + std::to_string(i) +
             "].outputStart does not match the cumulative duration of the "
             "preceding clips — gaps and overlaps require the transcode "
             "path";
    }
    cumulativeDuration += c.sourceDuration;
  }
  return std::nullopt;
}

} // namespace margelo::nitro::videopipeline
