///
/// Remuxer.hpp
///
/// Platform-agnostic helpers for the passthrough remux path (Video.trim,
/// Video.flip, multi-clip concat). The heavy lifting is platform-specific —
/// AVAssetReader→AVAssetWriter on iOS, Media3 Transformer's passthrough mode
/// on Android — so this header only holds the pieces that are worth sharing:
///   - `TrimSpec` — the requested trim window.
///   - `describeTrimRejection()` — precondition check run before any reader
///     or writer is opened, so the same InvalidSpec wording surfaces on both
///     platforms.
///   - `ConcatClipSpec` + `describeConcatRejection()` — the shape a single
///     clip on a multi-clip timeline takes and the v0.1 pre-flight validator.
///
/// When a second trigger branch (Android trim in T042+) wants the same
/// validation it can include this header directly. The iOS implementation in
/// `ios/Remuxer.mm` already does.
///

#pragma once

#include <optional>
#include <string>
#include <vector>

namespace margelo::nitro::videopipeline {

struct TrimSpec {
  double startSec;
  double durationSec;
};

/// Returns a human-readable reason when @p spec cannot be honored by any
/// remuxer implementation. Returns std::nullopt when the spec is valid.
///
/// @param sourceDurationSec Source clip duration, if already known. Pass
///                          std::nullopt to skip the bound check (e.g. to
///                          validate the spec before opening the source).
std::optional<std::string> describeTrimRejection(
    const TrimSpec& spec, std::optional<double> sourceDurationSec);

/// A single clip on a multi-clip concat timeline. Matches the JS-side
/// `Clip` struct's numeric fields — `transform` is carried separately on the
/// platform side because the concat path rejects any non-empty transform (per
/// T029 scope: "all clips, no transforms").
struct ConcatClipSpec {
  std::string uri;
  /// Seconds into the source clip at which the concat window begins.
  double sourceStart;
  /// Length of the concat window in source seconds. Must be > 0.
  double sourceDuration;
  /// Position of this clip on the output timeline, in seconds. The v0.1
  /// validator requires the vector to describe a contiguous timeline
  /// (clip[0].outputStart = 0, clip[i].outputStart = sum of prior
  /// sourceDuration values) so the concat can be pure passthrough with no
  /// black-frame padding; non-contiguous timelines fall back to transcode in
  /// later tasks.
  double outputStart;
};

/// Returns a human-readable reason when @p clips cannot be honored by the
/// v0.1 passthrough concat path. Returns std::nullopt when the spec is valid.
///
/// v0.1 acceptance window:
///   - @p clips must be non-empty.
///   - each @c sourceStart is finite and non-negative.
///   - each @c sourceDuration is finite and strictly positive.
///   - each @c outputStart is finite and non-negative.
///   - clips are contiguous: @c outputStart[0] is 0 (within 1 ms), and for
///     i ≥ 1, @c outputStart[i] equals the cumulative @c sourceDuration of
///     the preceding clips (within 1 ms). Gaps and overlaps route to the
///     transcode path that lands in later tasks.
std::optional<std::string> describeConcatRejection(
    const std::vector<ConcatClipSpec>& clips);

} // namespace margelo::nitro::videopipeline
