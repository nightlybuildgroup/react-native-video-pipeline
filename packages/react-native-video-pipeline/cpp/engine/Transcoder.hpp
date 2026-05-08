///
/// Transcoder.hpp
///
/// Platform-agnostic helpers for the transcode path — decode every source
/// frame, apply an optional transform (rotation / flip / crop), re-encode at
/// a (possibly different) resolution / codec / bitrate. The heavy lifting is
/// platform-specific (AVAssetReader + Core Image + AVAssetWriter on iOS;
/// Media3 Transformer's Effects pipeline on Android — T044+), so this header
/// only carries the pieces worth sharing:
///   - `TranscodeTarget` — the encoder-side output contract.
///   - `TranscodeSourceProbe` — minimal source metadata the validator needs.
///   - `describeTranscodeRejection()` — precondition check run before any
///     reader or writer is opened, so the same InvalidSpec wording surfaces
///     on both platforms.
///
/// Scope mirrors prd.md §16 T033: resolution/fps/codec/bitrate change + any
/// `ClipTransform` (rotation/flip/crop). Overlays are deferred to T034/T035.
///

#pragma once

#include <optional>
#include <string>

namespace margelo::nitro::videopipeline {

enum class TranscodeCodec {
  H264,
  HEVC,
};

/// Crop rectangle expressed in the source's natural-pixel frame, as the
/// public `ClipTransform.crop` does. The rectangle is applied BEFORE any
/// rotation / flip (prd.md §8: "source-pixel coordinates").
struct TranscodeCrop {
  double x;
  double y;
  double width;
  double height;
};

/// Encoder-side output contract. Dimensions are in pixels; `fps` is the
/// nominal output frame rate; `bitrate` is bits per second.
///
/// v0.1 frame-mapping semantics: every source sample becomes exactly one
/// output sample, retimed to PTS `sourceIndex / fps`. When `fps` matches the
/// source, the output plays back at real time; when it differs, the output
/// is simply stretched or compressed (no interpolation / decimation). This
/// is the simplest rule that preserves every decoded frame and avoids the
/// whole "fps conversion" rabbit hole, which no v0.1 consumer needs.
struct TranscodeTarget {
  int width;
  int height;
  double fps;
  TranscodeCodec codec;
  /// Encoder average bitrate in bits per second. `std::nullopt` → the
  /// platform driver picks a conservative per-resolution default.
  std::optional<int> bitrate;
  /// Extra rotation (in degrees, one of {0, 90, 180, 270}) applied on top of
  /// the source's preferredTransform. `std::nullopt` → preserve source.
  std::optional<int> rotate;
  bool flipH = false;
  bool flipV = false;
  std::optional<TranscodeCrop> crop;
};

/// Minimal source metadata the validator consults. Pass `std::nullopt` to
/// skip the bound check (e.g. when validating the target before opening the
/// source).
struct TranscodeSourceProbe {
  int width;
  int height;
  double durationSec;
};

/// Returns a human-readable reason when @p target cannot be honored by any
/// transcoder implementation. Returns std::nullopt when the target is valid.
std::optional<std::string> describeTranscodeRejection(
    const TranscodeTarget& target,
    const std::optional<TranscodeSourceProbe>& source);

} // namespace margelo::nitro::videopipeline
