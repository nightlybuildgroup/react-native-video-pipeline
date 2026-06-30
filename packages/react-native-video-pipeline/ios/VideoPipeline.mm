///
/// VideoPipeline.mm
///
/// iOS adapter entry point for `react-native-video-pipeline`. Methods
/// delegate to platform-specific runners (AVMuxer, WorkletFrameBridge,
/// SynthesizeRunner) as they land; everything not yet implemented rejects
/// with a typed "not implemented" error so the module links cleanly.
///
/// Subsequent iOS tasks replace the remaining stubs one method at a time:
///   T020 — Video.synthesize (fixed)       ← implemented
///   T021 — Video.synthesize (open-ended)  ← implemented
///   T025/T026 — AVDemuxer + info         → info()
///   T027 — remux trim                    ← implemented
///   T028 — rotation-flag flip            ← implemented
///   T030 — AVAssetImageGenerator         → thumbnail()
///   T031 — encoder capabilities          → capabilities()
///   T036 — stamp router                  → stamp()
///   T038 — AbortSignal plumbing          → cancelRender()
///   T039 — background task guard         ← each dispatch wraps in
///                                          RNVPBackgroundTaskGuard +
///                                          next-launch zombie drain
///   T041 — real worklet pump             → replaces test-pattern in SynthesizeRunner
///

#import "HybridVideoPipeline.hpp"

#import <AVFoundation/AVFoundation.h>

#import "AVDemuxer.h"
#import "AVMuxer.h"
#import "BackgroundTaskGuard.h"
#import "Capabilities.h"
#import "ExportSession.h"
#import "ExportSessionStamp.h"
#import "HybridFrameSource.h"
#import "HybridFrameTarget.h"
#import "OverlayRenderer.h"
#import "RNVPPathUtils.h"
#import "Remuxer.h"
#import "Remuxer+Internal.h"
#import "SynthesizeRunner.h"
#import "SynthesizeRunner+Internal.h"
#import "Thumbnailer.h"
#import "Transcoder.h"
#import "WorkletFrameBridge.h"

#import <Foundation/Foundation.h>

#import "compose/RenderTokenRegistry.hpp"
#import "compose/StopToken.hpp"

#import <chrono>
#import <exception>
#import <stdexcept>
#import <string>
#import <unordered_map>
#import <variant>

namespace margelo::nitro::videopipeline {

namespace {

std::runtime_error makeNotImplemented(const char* method) {
  return std::runtime_error(std::string("VideoPipeline.") + method +
                            ": not implemented yet on iOS");
}

// Adapt the Nitro-generated onProgress std::function into the
// RNVPProgressBlock signature used by SynthesizeRunner + Transcoder. Returns
// nil when onProgress is absent so runners can take the zero-cost fast path.
// The block packs the four scalars back into a `Progress` struct and invokes
// the Nitro callback, which is internally wrapped in `AsyncJSCallback` and
// marshals to the JS thread on its own side (see JSIConverter+Function.hpp).
RNVPProgressBlock progressBlockFromNitro(
    const std::optional<std::function<void(const Progress&)>>& onProgress) {
  if (!onProgress.has_value()) return nil;
  // Copy the std::function by value into the block so the backing JS
  // reference stays alive for the render's lifetime.
  auto callback = *onProgress;
  return ^(double framesCompleted, BOOL nbFramesValid, double nbFrames,
           double elapsedMs, BOOL etaMsValid,
           double estimatedRemainingMs) {
    Progress p;
    p.framesCompleted = framesCompleted;
    if (nbFramesValid) p.nbFrames = nbFrames;
    p.elapsedMs = elapsedMs;
    if (etaMsValid) p.estimatedRemainingMs = estimatedRemainingMs;
    callback(p);
  };
}

// Adapt the Nitro-generated onProgress std::function into the
// RNVPExportSessionProgress signature used by `RNVPExportSession`. That
// driver reports `(framesCompleted, nbFrames)` only — elapsedMs is
// synthesized here from a captured start time so the public `Progress`
// shape stays uniform across all paths.
RNVPExportSessionProgress exportSessionProgressFromNitro(
    const std::optional<std::function<void(const Progress&)>>& onProgress) {
  if (!onProgress.has_value()) return nil;
  auto callback = *onProgress;
  const NSTimeInterval startSec = [[NSDate date] timeIntervalSince1970];
  return ^(int32_t framesCompleted, int32_t nbFrames) {
    Progress p;
    p.framesCompleted = framesCompleted;
    if (nbFrames > 0) p.nbFrames = nbFrames;
    const NSTimeInterval nowSec = [[NSDate date] timeIntervalSince1970];
    p.elapsedMs = (nowSec - startSec) * 1000.0;
    callback(p);
  };
}

// Thin std::string → NSString bridges over the canonical, host-testable
// implementations in RNVPPathUtils.{h,mm}. `output.path` may legitimately
// arrive as either a bare path or a `file://` URI (e.g. expo-file-system's
// `File.uri`), exactly like the source `uri`/`outPath`; see issue #74.
NSURL* urlFromUri(const std::string& uri) {
  return RNVPURLFromUri([NSString stringWithUTF8String:uri.c_str()] ?: @"");
}

NSString* outputFilesystemPath(const std::string& path) {
  return RNVPOutputFilesystemPath([NSString stringWithUTF8String:path.c_str()] ?: @"");
}

std::string nsStringToUtf8(NSString* _Nullable s) {
  if (s == nil) return std::string();
  const char* utf8 = s.UTF8String;
  return utf8 != nullptr ? std::string(utf8) : std::string();
}

// Resolved audio directive for the native render paths. Maps the optional
// nitro AudioSpec onto the RNVPAudioMode the Obj-C drivers speak. A missing
// spec.audio (the common case) is Passthrough. Replace carries the resolved
// replacement file URL (nil if replaceUri was absent — the JS layer rejects
// that, and the native paths fall back to silent).
struct ResolvedAudio {
  RNVPAudioMode mode;
  NSURL* replacementURL;
};

ResolvedAudio resolveAudio(const VideoSpec& spec) {
  if (!spec.audio.has_value()) return {RNVPAudioModePassthrough, nil};
  switch (spec.audio->mode) {
    case AudioMode::PASSTHROUGH:
      return {RNVPAudioModePassthrough, nil};
    case AudioMode::MUTE:
      return {RNVPAudioModeMute, nil};
    case AudioMode::REPLACE:
      return {RNVPAudioModeReplace,
              spec.audio->replaceUri.has_value()
                  ? urlFromUri(*spec.audio->replaceUri)
                  : nil};
  }
  return {RNVPAudioModePassthrough, nil};
}

VideoInfo buildVideoInfoFromDemuxer(RNVPAVDemuxer* demuxer, const std::string& uri) {
  VideoInfo info;
  info.uri = uri;
  info.durationSec = demuxer.durationSec;
  // The demuxer stores the natural (pre-rotation) AVAssetTrack.naturalSize.
  // Public API contract: `width`/`height` are the displayed dimensions
  // (post-rotation) — `codedWidth`/`codedHeight` carry the natural grid.
  // Swap when the source's preferredTransform encodes a 90°/270° rotation.
  const NSInteger codedW = demuxer.width;
  const NSInteger codedH = demuxer.height;
  const BOOL rotatedSideways =
      (demuxer.rotation == 90 || demuxer.rotation == 270);
  info.width = static_cast<double>(rotatedSideways ? codedH : codedW);
  info.height = static_cast<double>(rotatedSideways ? codedW : codedH);
  info.codedWidth = static_cast<double>(codedW);
  info.codedHeight = static_cast<double>(codedH);
  info.fps = demuxer.fps;
  info.bitRate = static_cast<double>(demuxer.bitRate);
  info.fileSizeBytes = 0.0;
  if (NSURL* fileURL = urlFromUri(uri); fileURL.isFileURL) {
    NSError* sizeError = nil;
    NSDictionary<NSFileAttributeKey, id>* attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:fileURL.path
                         error:&sizeError];
    NSNumber* size = (NSNumber*)attrs[NSFileSize];
    if (size != nil) {
      info.fileSizeBytes = size.doubleValue;
    }
  }
  info.codec = nsStringToUtf8(demuxer.codec);
  info.container = nsStringToUtf8(demuxer.container);
  info.hasAudio = demuxer.hasAudio;
  info.isHDR = demuxer.isHDR;
  info.rotation = static_cast<double>(demuxer.rotation);

  NSDate* creationDate = demuxer.creationDate;
  if (creationDate != nil) {
    using namespace std::chrono;
    const double epochSeconds = creationDate.timeIntervalSince1970;
    const auto ns = nanoseconds(static_cast<int64_t>(epochSeconds * 1e9));
    info.creationDate = system_clock::time_point(
        duration_cast<system_clock::duration>(ns));
  }

  if (demuxer.hasLocation) {
    WGS84Coordinate coord{demuxer.locationLatitude,
                          demuxer.locationLongitude, std::nullopt};
    if (demuxer.hasLocationAltitude) {
      coord.altitude = demuxer.locationAltitude;
    }
    info.location = coord;
  }

  NSString* description = demuxer.contentDescription;
  if (description.length > 0) {
    info.description = nsStringToUtf8(description);
  }

  NSDictionary<NSString*, NSString*>* customDict = demuxer.customMetadata;
  if (customDict.count > 0) {
    std::unordered_map<std::string, std::string> custom;
    custom.reserve(customDict.count);
    for (NSString* key in customDict) {
      NSString* value = customDict[key];
      custom.emplace(nsStringToUtf8(key), nsStringToUtf8(value));
    }
    info.custom = std::move(custom);
  }
  return info;
}

std::runtime_error makeInvalidSpec(const std::string& detail) {
  return std::runtime_error(std::string("VideoPipeline.render: InvalidSpec — ") +
                            detail);
}

std::runtime_error makeCancelled() {
  return std::runtime_error("VideoPipeline.render: Cancelled");
}

// Per-process one-shot: on the first render-adjacent call after module
// load, drain any journal entries left over from a prior process kill.
// Deletes partial output files and clears the journal so a subsequent
// cancelRender on a zombie token is a no-op. Cheap when the journal is
// empty (default case).
void drainZombiesOnce() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    [RNVPBackgroundTaskJournal drainZombies];
  });
}

// Produce a unique journal token for call sites that don't receive a
// renderToken through the Nitro surface (e.g. @c Video.stamp). The string
// is opaque to JS — it only needs to be stable for the duration of the
// guarded block so begin/end pair up on the journal.
NSString* internalJournalToken(const char* prefix) {
  return [NSString stringWithFormat:@"%s-%@", prefix,
                                    NSUUID.UUID.UUIDString];
}

template <typename T>
std::shared_ptr<Promise<T>> rejectedNotImplemented(const char* method) {
  return Promise<T>::rejected(std::make_exception_ptr(makeNotImplemented(method)));
}

// Returns a description of which synthesize prerequisite is missing, or
// std::nullopt if the spec is a valid null-input synthesize (fixed or open).
// The JS layer already performs the same checks (`validateRenderSpec` in
// src/video.ts); this mirror guards against direct C++ callers and XCTests
// that bypass JS validation.
std::optional<std::string> describeSynthesizeRejection(const VideoSpec& spec) {
  if (!spec.duration.has_value()) {
    return "synthesize requires a duration";
  }
  if (std::holds_alternative<FixedDuration>(*spec.duration)) {
    const auto& fixed = std::get<FixedDuration>(*spec.duration);
    if (!(fixed.seconds > 0.0)) {
      return "duration.seconds must be > 0";
    }
  } else if (std::holds_alternative<OpenDuration>(*spec.duration)) {
    const auto& open = std::get<OpenDuration>(*spec.duration);
    if (open.maxSeconds.has_value() && !(*open.maxSeconds > 0.0)) {
      return "duration.maxSeconds must be > 0 when provided";
    }
  } else {
    return "unknown duration mode";
  }
  if (!spec.output.width.has_value() || !(*spec.output.width > 0.0)) {
    return "output.width is required and must be > 0";
  }
  if (!spec.output.height.has_value() || !(*spec.output.height > 0.0)) {
    return "output.height is required and must be > 0";
  }
  if (!spec.output.fps.has_value() || !(*spec.output.fps > 0.0)) {
    return "output.fps is required and must be > 0";
  }
  return std::nullopt;
}

// Returns a description of why the clip-based branch cannot be served by the
// v0.1 passthrough concat path, or std::nullopt if the spec is acceptable.
// Scope mirrors T029: no duration, no transforms, no overlays — any of these
// route to the transcode path in a later task.
std::optional<std::string> describeConcatBranchRejection(const VideoSpec& spec) {
  if (spec.duration.has_value()) {
    return "duration is only valid when clips is empty";
  }
  if (spec.overlays.has_value() && !spec.overlays->empty()) {
    return "overlays on a multi-clip spec require the transcode path "
           "(not wired yet)";
  }
  for (std::size_t i = 0; i < spec.clips->size(); ++i) {
    const auto& clip = (*spec.clips)[i];
    if (clip.transform.has_value()) {
      const auto& t = *clip.transform;
      const bool any = t.rotate.has_value() || t.flipH.value_or(false) ||
                       t.flipV.value_or(false) || t.crop.has_value();
      if (any) {
        return "clip[" + std::to_string(i) +
               "].transform requires the transcode path (not wired yet)";
      }
    }
  }
  return std::nullopt;
}

// True when @p clip carries any transform field that would require the
// transcode path (any one of rotate / flipH / flipV / crop set to a
// non-default value).
// Crop re-cuts the pixel grid, so it can only be honored by the transcode
// (re-encode) path. Rotation and flip, by contrast, are container-transform
// operations that the remux path expresses losslessly via preferredTransform.
bool clipHasCrop(const Clip& clip) {
  return clip.transform.has_value() && clip.transform->crop.has_value();
}
bool clipHasRotateOrFlip(const Clip& clip) {
  if (!clip.transform.has_value()) return false;
  const auto& t = *clip.transform;
  return t.rotate.has_value() || t.flipH.value_or(false) ||
         t.flipV.value_or(false);
}

// True when the caller's @c output section asks for encoder-side changes:
// any of width / height / fps / codec / bitrate is explicitly set. These
// require re-encoding regardless of source values.
bool outputAsksForReencode(const OutputSpec& output) {
  return output.width.has_value() || output.height.has_value() ||
         output.fps.has_value() || output.codec.has_value() ||
         output.bitrate.has_value();
}

// Returns a description of why the single-clip transcode branch cannot be
// served, or std::nullopt when the spec is acceptable. v0.1 scope:
//   - exactly one clip (multi-clip transcode lands in a later task),
//   - a trim window (sourceStart / sourceDuration) is allowed — the transcoder
//     restricts its reader to that range and rebases output PTS, so render can
//     trim and transform (crop / resize / re-encode) in a single pass.
//   - no overlays (T034/T035),
//   - output.width/height/fps all finite positive when set.
std::optional<std::string> describeTranscodeBranchRejection(
    const VideoSpec& spec, double sourceDurationSec) {
  if (spec.duration.has_value()) {
    return "duration is only valid when clips is empty";
  }
  if (spec.clips->size() != 1) {
    return "multi-clip transcode is not wired yet — use a single clip or "
           "the concat passthrough path";
  }
  // Image and text overlays both flow through the transcode path via
  // RNVPOverlayRenderer; no per-kind rejection needed here. Worklet overlays
  // are not part of NativeOverlay and never reach this validator.
  const auto& clip = (*spec.clips)[0];
  // A trim window (sourceStart / sourceDuration) is now honored by the
  // transcoder — video frames are gated by source PTS and the audio passthrough
  // is gated and PTS-shifted to the same window — so it is no longer rejected
  // here. Bound the window to the source: a start past EOF is unusable.
  if (clip.sourceStart > sourceDurationSec + 1e-3) {
    return "transcode: sourceStart is past the end of the source";
  }
  if (clip.outputStart > 1e-3) {
    return "outputStart must be 0 on a single-clip render";
  }
  if (spec.output.width.has_value() && !(*spec.output.width > 0.0)) {
    return "output.width must be > 0 when provided";
  }
  if (spec.output.height.has_value() && !(*spec.output.height > 0.0)) {
    return "output.height must be > 0 when provided";
  }
  if (spec.output.fps.has_value() && !(*spec.output.fps > 0.0)) {
    return "output.fps must be > 0 when provided";
  }
  return std::nullopt;
}

// Build a transcode target for one clip on a multi-clip timeline: the clip's
// own transform (rotate / flip / crop) and trim window, but explicit *shared*
// output dimensions / fps / codec / bitrate so every clip re-encodes to an
// identical output that the lossless concat can then join. Used by the
// multi-clip transcode-each-then-concat path (#14).
RNVPTranscodeTarget* buildTranscodeTargetForClip(const Clip& clip,
                                                 NSInteger outW, NSInteger outH,
                                                 double fps,
                                                 RNVPTranscodeCodec codec,
                                                 NSInteger bitrate) {
  NSInteger rotate = -1;
  BOOL flipH = NO;
  BOOL flipV = NO;
  double cropX = 0.0, cropY = 0.0, cropWidth = 0.0, cropHeight = 0.0;
  if (clip.transform.has_value()) {
    const auto& t = *clip.transform;
    if (t.rotate.has_value()) rotate = static_cast<NSInteger>(std::lround(*t.rotate));
    flipH = t.flipH.value_or(false) ? YES : NO;
    flipV = t.flipV.value_or(false) ? YES : NO;
    if (t.crop.has_value()) {
      const auto& c = *t.crop;
      cropX = c.x;
      cropY = c.y;
      cropWidth = c.w;
      cropHeight = c.h;
    }
  }
  return [[RNVPTranscodeTarget alloc] initWithWidth:outW
                                             height:outH
                                                fps:fps
                                              codec:codec
                                            bitrate:bitrate
                                             rotate:rotate
                                              flipH:flipH
                                              flipV:flipV
                                              cropX:cropX
                                              cropY:cropY
                                          cropWidth:cropWidth
                                         cropHeight:cropHeight
                                        sourceStart:clip.sourceStart
                                     sourceDuration:clip.sourceDuration];
}

// Author a black, silent clip of @p seconds at the given output dimensions /
// fps — used to fill timeline gaps (#18) before concatenation. Video-only (the
// concat leaves a silent span for it). Returns NO on failure / cancellation,
// deleting any partial file.
bool authorBlackClip(NSString* path, NSInteger width, NSInteger height,
                     double fps, double seconds, RNVPStopToken* stop,
                     NSError* __autoreleasing* error) {
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  const NSInteger ifps = static_cast<NSInteger>(std::llround(fps > 0.0 ? fps : 30.0));
  RNVPAVMuxer* muxer = [[RNVPAVMuxer alloc] init];
  if (![muxer openVideoOnlyAtPath:path width:width height:height fps:ifps error:error]) {
    return false;
  }
  CVPixelBufferRef pb = NULL;
  NSDictionary* pbAttrs = @{(NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{}};
  if (CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                          kCVPixelFormatType_32BGRA,
                          (__bridge CFDictionaryRef)pbAttrs, &pb) != kCVReturnSuccess) {
    if (error) {
      *error = [NSError errorWithDomain:@"RNVPVideoPipeline"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"could not allocate a black gap frame"
                               }];
    }
    [muxer closeWithError:nil];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return false;
  }
  CVPixelBufferLockBaseAddress(pb, 0);
  std::memset(CVPixelBufferGetBaseAddress(pb), 0,
              CVPixelBufferGetBytesPerRow(pb) * static_cast<size_t>(height));
  CVPixelBufferUnlockBaseAddress(pb, 0);
  // Author at least `seconds` of black (ceil to whole frames) so the caller can
  // claim the exact gap duration when splicing — never less than requested.
  const NSInteger frames = std::max<NSInteger>(
      1, static_cast<NSInteger>(std::ceil(seconds * static_cast<double>(ifps))));
  bool ok = true;
  for (NSInteger i = 0; i < frames; i++) {
    if (stop != nil && stop.abortRequested) { ok = false; break; }
    while (!muxer.videoInputIsReady && !muxer.videoInputFailed) {
      if (stop != nil && stop.abortRequested) break;
      [NSThread sleepForTimeInterval:0.001];
    }
    if (muxer.videoInputFailed || (stop != nil && stop.abortRequested)) {
      ok = false;
      break;
    }
    if (![muxer appendPixelBuffer:pb
                 presentationTime:CMTimeMake(i, static_cast<int32_t>(ifps))
                            error:error]) {
      ok = false;
      break;
    }
  }
  CVPixelBufferRelease(pb);
  if (!ok) {
    [muxer closeWithError:nil];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return false;
  }
  return [muxer closeWithError:error];
}

RNVPTranscodeTarget* buildTranscodeTarget(const VideoSpec& spec,
                                          NSInteger sourceW,
                                          NSInteger sourceH,
                                          double sourceFps) {
  NSInteger rotate = -1;
  BOOL flipH = NO;
  BOOL flipV = NO;
  double cropX = 0.0;
  double cropY = 0.0;
  double cropWidth = 0.0;
  double cropHeight = 0.0;
  const auto& clip = (*spec.clips)[0];
  if (clip.transform.has_value()) {
    const auto& t = *clip.transform;
    if (t.rotate.has_value()) {
      rotate = static_cast<NSInteger>(std::lround(*t.rotate));
    }
    flipH = t.flipH.value_or(false) ? YES : NO;
    flipV = t.flipV.value_or(false) ? YES : NO;
    if (t.crop.has_value()) {
      const auto& c = *t.crop;
      cropX = c.x;
      cropY = c.y;
      cropWidth = c.w;
      cropHeight = c.h;
    }
  }

  // Default output dimensions track the *displayed* content when the caller
  // doesn't pin them: the crop rect if present (else the source), with width
  // and height swapped for a quarter-turn rotation. This keeps an unspecified
  // crop / rotate from being non-uniformly scaled back to the source frame.
  const NSInteger contentW = cropWidth > 0.0
                                 ? static_cast<NSInteger>(std::lround(cropWidth))
                                 : sourceW;
  const NSInteger contentH =
      cropHeight > 0.0 ? static_cast<NSInteger>(std::lround(cropHeight))
                       : sourceH;
  const BOOL swapDims = (rotate == 90 || rotate == 270);
  const NSInteger fallbackW = swapDims ? contentH : contentW;
  const NSInteger fallbackH = swapDims ? contentW : contentH;

  const NSInteger width = spec.output.width.has_value()
                              ? static_cast<NSInteger>(
                                    std::lround(*spec.output.width))
                              : fallbackW;
  const NSInteger height = spec.output.height.has_value()
                               ? static_cast<NSInteger>(
                                     std::lround(*spec.output.height))
                               : fallbackH;
  const double fps =
      spec.output.fps.has_value() ? *spec.output.fps : sourceFps;
  const RNVPTranscodeCodec codec =
      spec.output.codec.value_or(VideoCodec::H264) == VideoCodec::HEVC
          ? RNVPTranscodeCodecHEVC
          : RNVPTranscodeCodecH264;
  const NSInteger bitrate =
      spec.output.bitrate.has_value()
          ? static_cast<NSInteger>(std::lround(*spec.output.bitrate))
          : 0;

  return [[RNVPTranscodeTarget alloc] initWithWidth:width
                                             height:height
                                                fps:fps
                                              codec:codec
                                            bitrate:bitrate
                                             rotate:rotate
                                              flipH:flipH
                                              flipV:flipV
                                              cropX:cropX
                                              cropY:cropY
                                          cropWidth:cropWidth
                                         cropHeight:cropHeight
                                        sourceStart:clip.sourceStart
                                     sourceDuration:clip.sourceDuration];
}

// Flatten one nitro NativeOverlay (@c ImageOverlay or @c TextOverlay) into
// its Obj-C counterpart and append to @p out. Shared by the single-clip
// transcode branch of @c render() and the watermark branch of @c stamp() so
// the two paths agree by construction on anchor/size/opacity/time-range
// semantics. Worklet overlays are not part of @c NativeOverlay and never
// reach this helper.
void appendNativeOverlay(
    NSMutableArray* out,
    const std::variant<ImageOverlay, TextOverlay>& overlay) {
  if (std::holds_alternative<ImageOverlay>(overlay)) {
    const auto& img = std::get<ImageOverlay>(overlay);
    NSURL* imageURL = urlFromUri(img.uri);
    const BOOL hasSizeW = img.size.w.has_value();
    const BOOL sizeWIsRatio = hasSizeW && img.size.w->unit == SizeUnit::RATIO;
    const double sizeWValue = hasSizeW ? img.size.w->value : 0.0;
    const BOOL hasSizeH = img.size.h.has_value();
    const BOOL sizeHIsRatio = hasSizeH && img.size.h->unit == SizeUnit::RATIO;
    const double sizeHValue = hasSizeH ? img.size.h->value : 0.0;
    const double opacity = img.opacity.has_value() ? *img.opacity : 1.0;
    BOOL hasTimeRange = NO;
    double startSec = 0.0;
    double endSec = 0.0;
    if (img.timeRange.has_value()) {
      hasTimeRange = YES;
      startSec = img.timeRange->startSec;
      endSec = img.timeRange->endSec;
    }
    [out addObject:[[RNVPImageOverlay alloc] initWithImageURL:imageURL
                                                      anchorX:img.anchor.x
                                                      anchorY:img.anchor.y
                                                     hasSizeW:hasSizeW
                                                 sizeWIsRatio:sizeWIsRatio
                                                   sizeWValue:sizeWValue
                                                     hasSizeH:hasSizeH
                                                 sizeHIsRatio:sizeHIsRatio
                                                   sizeHValue:sizeHValue
                                                      opacity:opacity
                                                 hasTimeRange:hasTimeRange
                                                     startSec:startSec
                                                       endSec:endSec]];
    return;
  }
  const auto& t = std::get<TextOverlay>(overlay);
  NSString* text = [NSString stringWithUTF8String:t.text.c_str()] ?: @"";
  NSString* fontFamily = nil;
  if (t.style.fontFamily.has_value()) {
    fontFamily =
        [NSString stringWithUTF8String:t.style.fontFamily->c_str()];
  }
  NSString* colorStr =
      [NSString stringWithUTF8String:t.style.color.c_str()] ?: @"";
  const BOOL weightBold = t.style.weight.has_value() &&
                          *t.style.weight == FontWeight::BOLD;
  RNVPTextAlignment alignment = RNVPTextAlignmentLeft;
  if (t.style.align.has_value()) {
    switch (*t.style.align) {
      case TextAlign::LEFT:
        alignment = RNVPTextAlignmentLeft;
        break;
      case TextAlign::CENTER:
        alignment = RNVPTextAlignmentCenter;
        break;
      case TextAlign::RIGHT:
        alignment = RNVPTextAlignmentRight;
        break;
    }
  }
  BOOL hasShadow = NO;
  NSString* shadowColorStr = nil;
  double shadowBlur = 0.0;
  double shadowDx = 0.0;
  double shadowDy = 0.0;
  if (t.style.shadow.has_value()) {
    hasShadow = YES;
    const auto& sh = *t.style.shadow;
    shadowColorStr =
        [NSString stringWithUTF8String:sh.color.c_str()] ?: @"";
    shadowBlur = sh.blur;
    shadowDx = sh.dx;
    shadowDy = sh.dy;
  }
  BOOL hasTimeRange = NO;
  double startSec = 0.0;
  double endSec = 0.0;
  if (t.timeRange.has_value()) {
    hasTimeRange = YES;
    startSec = t.timeRange->startSec;
    endSec = t.timeRange->endSec;
  }
  [out addObject:[[RNVPTextOverlay alloc] initWithText:text
                                            fontFamily:fontFamily
                                              fontSize:t.style.fontSize
                                           colorString:colorStr
                                            weightBold:weightBold
                                             alignment:alignment
                                             hasShadow:hasShadow
                                     shadowColorString:shadowColorStr
                                            shadowBlur:shadowBlur
                                              shadowDx:shadowDx
                                              shadowDy:shadowDy
                                               anchorX:t.anchor.x
                                               anchorY:t.anchor.y
                                          hasTimeRange:hasTimeRange
                                              startSec:startSec
                                                endSec:endSec]];
}

// Whether an overlay is time-ranged (visible only for part of the timeline).
// Multi-clip re-encode applies overlays per-clip, so a time-ranged overlay
// would be mis-timed against the joined output — the caller rejects that case.
bool overlayHasTimeRange(const std::variant<ImageOverlay, TextOverlay>& o) {
  if (std::holds_alternative<ImageOverlay>(o)) {
    return std::get<ImageOverlay>(o).timeRange.has_value();
  }
  return std::get<TextOverlay>(o).timeRange.has_value();
}

// Translate an optional @c MetadataSpec (nitro) into an Obj-C
// @c RNVPStampMetadata. A nil return means "no metadata stamp" — the
// caller should leave @c writer.metadata at its default passthrough.
RNVPStampMetadata* buildStampMetadata(
    const std::optional<MetadataSpec>& metadata) {
  if (!metadata.has_value()) return nil;
  const auto& m = *metadata;
  BOOL hasGps = NO;
  double latitude = 0.0;
  double longitude = 0.0;
  BOOL hasGpsAltitude = NO;
  double altitude = 0.0;
  if (m.location.has_value()) {
    hasGps = YES;
    latitude = m.location->latitude;
    longitude = m.location->longitude;
    if (m.location->altitude.has_value()) {
      hasGpsAltitude = YES;
      altitude = *m.location->altitude;
    }
  }
  NSString* software = nil;
  if (m.software.has_value()) {
    software = [NSString stringWithUTF8String:m.software->c_str()];
  }
  NSDate* creationDate = nil;
  if (m.creationDate.has_value()) {
    using namespace std::chrono;
    const auto ns =
        duration_cast<nanoseconds>(m.creationDate->time_since_epoch());
    const double seconds = static_cast<double>(ns.count()) / 1e9;
    creationDate = [NSDate dateWithTimeIntervalSince1970:seconds];
  }
  NSString* contentDescription = nil;
  if (m.description.has_value()) {
    contentDescription =
        [NSString stringWithUTF8String:m.description->c_str()];
  }
  NSDictionary<NSString*, NSString*>* custom = nil;
  if (m.custom.has_value() && !m.custom->empty()) {
    NSMutableDictionary<NSString*, NSString*>* mutableCustom =
        [NSMutableDictionary dictionaryWithCapacity:m.custom->size()];
    for (const auto& entry : *m.custom) {
      NSString* key = [NSString stringWithUTF8String:entry.first.c_str()];
      NSString* value = [NSString stringWithUTF8String:entry.second.c_str()];
      if (key != nil && value != nil) {
        mutableCustom[key] = value;
      }
    }
    custom = [mutableCustom copy];
  }
  return [[RNVPStampMetadata alloc] initWithGps:hasGps
                                        latitude:latitude
                                       longitude:longitude
                                  hasGpsAltitude:hasGpsAltitude
                                        altitude:altitude
                                        software:software
                                    creationDate:creationDate
                              contentDescription:contentDescription
                                          custom:custom];
}

} // namespace

// --- Probe -----------------------------------------------------------------

std::shared_ptr<Promise<VideoInfo>> HybridVideoPipeline::info(const std::string& uri) {
  const std::string uriCopy = uri;
  NSURL* url = urlFromUri(uri);
  return Promise<VideoInfo>::async([uriCopy, url]() -> VideoInfo {
    RNVPAVDemuxer* demuxer = [[RNVPAVDemuxer alloc] init];
    NSError* openError = nil;
    if (![demuxer openAtURL:url error:&openError]) {
      const char* desc =
          openError.localizedDescription.UTF8String ?: "(unknown error)";
      throw std::runtime_error(std::string("VideoPipeline.info failed: ") + desc);
    }
    VideoInfo info = buildVideoInfoFromDemuxer(demuxer, uriCopy);
    [demuxer closeWithError:nullptr];
    return info;
  });
}

std::shared_ptr<Promise<std::string>> HybridVideoPipeline::thumbnail(
    const std::string& uri, const ThumbnailOptions& options) {
  NSURL* sourceURL = urlFromUri(uri);
  NSURL* outputURL = urlFromUri(options.outPath);
  std::string outPathCopy = options.outPath;
  const double atSec = options.atSec;
  // Size fields are optional doubles; 0.0 sentinels match Thumbnailer's
  // "not specified" contract.
  double resizeW = 0.0;
  double resizeH = 0.0;
  if (options.resizeTo.has_value()) {
    const auto& s = *options.resizeTo;
    if (s.w.has_value()) resizeW = *s.w;
    if (s.h.has_value()) resizeH = *s.h;
  }
  return Promise<std::string>::async(
      [sourceURL, outputURL, atSec, resizeW, resizeH,
       outPathCopy]() -> std::string {
        NSError* err = nil;
        const BOOL ok =
            [RNVPThumbnailer generateThumbnailFromURL:sourceURL
                                                toURL:outputURL
                                                atSec:atSec
                                          resizeWidth:resizeW
                                         resizeHeight:resizeH
                                                error:&err];
        if (!ok) {
          const char* desc = err.localizedDescription.UTF8String ?: "(nil)";
          throw std::runtime_error(
              std::string("VideoPipeline.thumbnail failed: ") + desc);
        }
        return outPathCopy;
      });
}

std::shared_ptr<Promise<EncoderCaps>> HybridVideoPipeline::capabilities() {
  // Hop to Nitro's background pool — the first call runs VTCompressionSession
  // probes (~milliseconds, but enough to merit staying off the JS thread),
  // and subsequent calls are cache hits that finish in a single lock
  // acquisition. Same pattern regardless of cache state to keep the contract
  // uniform from JS's perspective.
  return Promise<EncoderCaps>::async([]() -> EncoderCaps {
    RNVPEncoderCapabilities* probed = [RNVPCapabilities probe];
    std::vector<VideoCodec> codecs;
    codecs.reserve(probed.codecs.count);
    for (NSString* tag in probed.codecs) {
      if ([tag isEqualToString:@"h264"]) {
        codecs.push_back(VideoCodec::H264);
      } else if ([tag isEqualToString:@"hevc"]) {
        codecs.push_back(VideoCodec::HEVC);
      }
      // Any other tag is silently dropped — the Nitro enum only admits
      // h264/hevc, and the Obj-C probe never emits anything else. Future
      // codecs (AV1, VP9) would require an extension to the VideoCodec
      // union in the Nitro spec first.
    }
    return EncoderCaps(
        std::move(codecs),
        static_cast<double>(probed.maxWidth),
        static_cast<double>(probed.maxHeight),
        probed.maxFps,
        static_cast<double>(probed.maxBitrate),
        static_cast<bool>(probed.hdr));
  });
}

// --- Auto-routed render ----------------------------------------------------

std::shared_ptr<Promise<void>> HybridVideoPipeline::render(
    const VideoSpec& spec,
    const std::string& renderToken,
    const std::optional<std::function<void(const Progress&)>>& onProgress) {
  // Clean up any renders left journaled from a previous process that was
  // killed by the OS before its completion block ran. Idempotent — the
  // dispatch_once gate only fires once per process regardless of how many
  // renders the consumer kicks off.
  drainZombiesOnce();

  const bool isSynthesized =
      !spec.clips.has_value() || spec.clips->empty();

  if (!isSynthesized) {
    // Decide between the passthrough concat path and the transcode path:
    // anything that requires re-encoding (a non-empty clip transform or an
    // explicit output change — width/height/fps/codec/bitrate) on a single-
    // clip render routes to the transcoder. Multi-clip specs stay on the
    // concat path until a later task extends multi-clip transcode.
    const bool single = spec.clips->size() == 1;
    const bool hasOverlays =
        spec.overlays.has_value() && !spec.overlays->empty();
    // A timeline gap (a clip whose outputStart is past the previous clip's end)
    // is filled with black + silence, which forces a re-encode through the
    // multi-clip transcode path (you can't passthrough-concat black).
    bool hasGap = false;
    // A timeline overlap (a clip whose outputStart is before the previous
    // clip's end) is crossfade-composited (#18 overlaps), which also forces a
    // re-encode (a blended frame can't be passthrough-concatenated).
    bool hasOverlap = false;
    // Overlay/PiP tracks (#17): a clip with track > 0 layers spatially on top of
    // the base (track 0) timeline. They don't participate in the base concat, so
    // gap/overlap detection runs over base clips only.
    bool hasOverlayTracks = false;
    auto clipTrack = [](const Clip& c) -> double {
      return c.track.value_or(0.0);
    };
    {
      double prevEnd = 0.0;
      for (const auto& c : *spec.clips) {
        if (clipTrack(c) > 0.5) {
          hasOverlayTracks = true;
          continue;
        }
        if (c.outputStart > prevEnd + 1e-3) {
          hasGap = true;
        } else if (c.outputStart < prevEnd - 1e-3) {
          hasOverlap = true;
        }
        prevEnd = c.outputStart + c.sourceDuration;
      }
    }
    // Crop, an output-side re-encode (width/height/fps/codec/bitrate), or any
    // overlay forces the transcode path. Rotation/flip alone do NOT — they take
    // the fast remux-transform path below, which also carries any trim window.
    // A gap always re-encodes, so it never takes the single fast paths.
    const bool needsTranscode =
        single && !hasGap && !hasOverlayTracks &&
        (clipHasCrop((*spec.clips)[0]) || outputAsksForReencode(spec.output) ||
         hasOverlays);
    if (needsTranscode) {
      // Probe the source so the transcode-branch validator can enforce the
      // "full-source-only" window and so the target inherits unspecified
      // dimensions from the source. Probe failure routes straight to a
      // typed rejection — the file either doesn't exist or isn't a video.
      NSURL* clipURL = urlFromUri((*spec.clips)[0].uri);
      RNVPAVDemuxer* demuxer = [[RNVPAVDemuxer alloc] init];
      NSError* probeErr = nil;
      if (![demuxer openAtURL:clipURL error:&probeErr]) {
        const char* desc =
            probeErr.localizedDescription.UTF8String ?: "(nil)";
        return Promise<void>::rejected(std::make_exception_ptr(
            std::runtime_error(std::string("VideoPipeline.render "
                                            "transcode probe failed: ") +
                               desc)));
      }
      const NSInteger sourceW = demuxer.width;
      const NSInteger sourceH = demuxer.height;
      const double sourceFps = demuxer.fps > 0.0 ? demuxer.fps : 30.0;
      const double sourceDurationSec = demuxer.durationSec;
      [demuxer closeWithError:nullptr];

      if (auto rejection =
              describeTranscodeBranchRejection(spec, sourceDurationSec);
          rejection.has_value()) {
        return Promise<void>::rejected(
            std::make_exception_ptr(makeInvalidSpec(*rejection)));
      }

      RNVPTranscodeTarget* target =
          buildTranscodeTarget(spec, sourceW, sourceH, sourceFps);
      NSURL* outputURL = urlFromUri(spec.output.path);
      const ResolvedAudio resolvedAudio = resolveAudio(spec);
      const RNVPAudioMode audioMode = resolvedAudio.mode;
      NSURL* audioReplacementURL = resolvedAudio.replacementURL;

      NSMutableArray* nativeOverlays = nil;
      if (spec.overlays.has_value() && !spec.overlays->empty()) {
        nativeOverlays = [NSMutableArray
            arrayWithCapacity:spec.overlays->size()];
        for (const auto& overlay : *spec.overlays) {
          appendNativeOverlay(nativeOverlays, overlay);
        }
      }

      RNVPTranscoderProgressBlock progressBlock =
          progressBlockFromNitro(onProgress);
      const std::string tokenCopy = renderToken;
      std::shared_ptr<StopToken> stop =
          !renderToken.empty()
              ? RenderTokenRegistry::registerToken(renderToken)
              : std::make_shared<StopToken>();
      RNVPStopToken* runnerToken = [RNVPStopToken tokenFromSharedPtr:stop];
      NSString* journalToken =
          !renderToken.empty()
              ? [NSString stringWithUTF8String:renderToken.c_str()]
              : internalJournalToken("render-transcode");
      // Bare path (not the raw file:// URI) so zombie cleanup's fileExistsAtPath:
      // / removeItemAtPath: match the file the muxer actually writes (#74).
      NSString* outputPathForJournal = outputFilesystemPath(spec.output.path);
      RNVPBackgroundTaskGuard* guard =
          [RNVPBackgroundTaskGuard beginWithTokenId:journalToken
                                         outputPath:outputPathForJournal
                                          stopToken:runnerToken];
      return Promise<void>::async(
          [clipURL, outputURL, target, nativeOverlays, audioMode,
           audioReplacementURL, runnerToken, tokenCopy, progressBlock,
           guard]() {
        NSError* err = nil;
        const BOOL ok = [RNVPTranscoder transcodeFromURL:clipURL
                                                   toURL:outputURL
                                                  target:target
                                                overlays:nativeOverlays
                                                metadata:nil
                                               audioMode:audioMode
                                     audioReplacementURL:audioReplacementURL
                                                    stop:runnerToken
                                                progress:progressBlock
                                                   error:&err];
        RenderTokenRegistry::unregisterToken(tokenCopy);
        [guard end];
        if (!ok) {
          if (err != nil && [err.domain isEqualToString:
                                            RNVPTranscoderErrorDomain] &&
              err.code == RNVPTranscoderErrorCodeCancelled) {
            throw makeCancelled();
          }
          const char* desc = err.localizedDescription.UTF8String ?: "(nil)";
          throw std::runtime_error(std::string("VideoPipeline.render "
                                                "transcode failed: ") +
                                   desc);
        }
      });
    }

    // Multi-clip render that needs a re-encode (#14): a per-clip transform, an
    // overlay, an output-side change, or a timeline gap (#18). Transcode each
    // clip to a temp at the shared output spec (reusing the single-clip
    // transcoder, which bakes the per-clip transform/crop/overlay), insert a
    // black+silent temp for each gap, then losslessly concat the matching temps.
    bool anyClipTransform = false;
    for (const auto& c : *spec.clips) {
      if (clipHasRotateOrFlip(c) || clipHasCrop(c)) {
        anyClipTransform = true;
        break;
      }
    }
    // A gap routes here even on a single clip (a leading-gap render is
    // [black, clip]); otherwise multi-clip + any re-encode trigger.
    const bool multiNeedsTranscode =
        hasGap || hasOverlap || hasOverlayTracks ||
        (!single && (anyClipTransform ||
                     outputAsksForReencode(spec.output) || hasOverlays));
    if (multiNeedsTranscode) {
      if (spec.duration.has_value()) {
        return Promise<void>::rejected(std::make_exception_ptr(
            makeInvalidSpec("duration is only valid when clips is empty")));
      }
      // Multi-clip re-encode applies overlays per-clip, so a time-ranged overlay
      // would land relative to each clip's own timeline, not the joined output.
      // Reject it until the timeline-aware multi-clip overlay path lands; static
      // overlays (a watermark across the whole output) are fine.
      if (spec.overlays.has_value()) {
        for (const auto& o : *spec.overlays) {
          if (overlayHasTimeRange(o)) {
            return Promise<void>::rejected(std::make_exception_ptr(makeInvalidSpec(
                "time-ranged overlays on a multi-clip re-encode are not "
                "supported yet — the overlay would be applied per-clip, not over "
                "the joined timeline; use a static overlay or render per clip")));
          }
        }
      }
      // Overlaps (clip.outputStart before the previous clip's end) are
      // crossfade-composited below; gaps are filled with black. Only
      // adjacent-pair overlaps are supported — the crossfade composer rejects a
      // clip overlapping two neighbours at once / full containment.
      //
      // The black gap fill is authored as H.264 (RNVPAVMuxer) and the crossfade
      // re-encode runs through AVAssetExportPresetHighestQuality (H.264), so
      // neither can target an HEVC output yet. Reject gaps/overlaps + HEVC until
      // the fill / crossfade encode respects the output codec.
      //
      // Overlay/PiP tracks (#17) take the same HighestQuality composite path,
      // so they share the HEVC limit; and that preset doesn't honor an explicit
      // bitrate, so reject a pinned bitrate on the overlay path rather than
      // silently ignoring it.
      if ((hasGap || hasOverlap || hasOverlayTracks) &&
          spec.output.codec.value_or(VideoCodec::H264) == VideoCodec::HEVC) {
        return Promise<void>::rejected(std::make_exception_ptr(makeInvalidSpec(
            "timeline gaps/overlaps/overlay tracks with an HEVC output are not "
            "supported yet — the black gap fill and the crossfade/overlay "
            "re-encode are authored as H.264; use the default H.264 output")));
      }
      if (hasOverlayTracks && spec.output.bitrate.has_value()) {
        return Promise<void>::rejected(std::make_exception_ptr(makeInvalidSpec(
            "an explicit output.bitrate is not supported with overlay tracks "
            "yet — the PiP composite re-encodes at the encoder's quality "
            "default; drop output.bitrate")));
      }
      // The base/overlay split below indexes baseClips[0]; a direct native
      // caller could bypass the JS "overlay needs a base" check, so guard it.
      if (hasOverlayTracks) {
        bool anyBase = false;
        for (const auto& c : *spec.clips) {
          if (c.track.value_or(0.0) <= 0.5) {
            anyBase = true;
            break;
          }
        }
        if (!anyBase) {
          return Promise<void>::rejected(std::make_exception_ptr(makeInvalidSpec(
              "an overlay track (clip.track > 0) requires at least one base "
              "(track 0) clip to composite onto")));
        }
      }
      NSMutableArray* nativeOverlays = nil;
      if (spec.overlays.has_value() && !spec.overlays->empty()) {
        nativeOverlays =
            [NSMutableArray arrayWithCapacity:spec.overlays->size()];
        for (const auto& overlay : *spec.overlays) {
          appendNativeOverlay(nativeOverlays, overlay);
        }
      }
      const std::vector<Clip> clipsCopy = *spec.clips;
      const OutputSpec outputCopy = spec.output;
      const ResolvedAudio audio = resolveAudio(spec);
      // Each clip transcodes muted unless the whole render is passthrough; the
      // soundtrack is then authored once by the concat (passthrough joins each
      // clip's audio, replace inserts the replacement over the full timeline).
      const RNVPAudioMode perClipAudio = audio.mode == RNVPAudioModePassthrough
                                             ? RNVPAudioModePassthrough
                                             : RNVPAudioModeMute;
      const RNVPAudioMode concatAudio = audio.mode;
      NSURL* concatReplacementURL = audio.replacementURL;
      NSURL* outputURL = urlFromUri(spec.output.path);

      const std::string tokenCopy = renderToken;
      std::shared_ptr<StopToken> stop =
          !renderToken.empty()
              ? RenderTokenRegistry::registerToken(renderToken)
              : std::make_shared<StopToken>();
      RNVPStopToken* runnerToken = [RNVPStopToken tokenFromSharedPtr:stop];
      NSString* journalToken =
          !renderToken.empty()
              ? [NSString stringWithUTF8String:renderToken.c_str()]
              : internalJournalToken("render-multi-transcode");
      // Bare path (not the raw file:// URI) so zombie cleanup's fileExistsAtPath:
      // / removeItemAtPath: match the file the muxer actually writes (#74).
      NSString* outputPathForJournal = outputFilesystemPath(spec.output.path);
      RNVPBackgroundTaskGuard* guard =
          [RNVPBackgroundTaskGuard beginWithTokenId:journalToken
                                         outputPath:outputPathForJournal
                                          stopToken:runnerToken];

      return Promise<void>::async([clipsCopy, outputCopy, nativeOverlays,
                                   perClipAudio, concatAudio,
                                   concatReplacementURL, outputURL, runnerToken,
                                   tokenCopy, guard, hasOverlap,
                                   hasOverlayTracks]() {
        NSMutableArray<NSString*>* temps = [NSMutableArray array];
        void (^teardown)(void) = ^{
          RenderTokenRegistry::unregisterToken(tokenCopy);
          [guard end];
          for (NSString* p in temps) {
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
          }
        };

        // Split the base (track 0) timeline from overlay/PiP tracks (#17). The
        // base joins as usual; overlays are composited on top afterwards. The
        // join target is the real output for a plain render, or a temp when
        // overlays still have to be layered on.
        std::vector<Clip> baseClips, overlayClips;
        for (const auto& c : clipsCopy) {
          if (c.track.value_or(0.0) > 0.5) {
            overlayClips.push_back(c);
          } else {
            baseClips.push_back(c);
          }
        }
        NSString* baseTempPath = nil;
        if (hasOverlayTracks) {
          baseTempPath = [NSTemporaryDirectory()
              stringByAppendingPathComponent:
                  [NSString stringWithFormat:@"rnvp-mt-base-%@.mp4",
                                             [[NSUUID UUID] UUIDString]]];
          [temps addObject:baseTempPath];
        }
        NSURL* joinURL =
            baseTempPath != nil ? [NSURL fileURLWithPath:baseTempPath] : outputURL;

        // Shared output dimensions: pinned values win, else derive from clip[0]
        // (post its own rotation) — the multi-clip analogue of the single-clip
        // fallback. Every clip re-encodes to these dims so the concat can join.
        NSError* probeErr = nil;
        NSURL* clip0URL = urlFromUri(baseClips[0].uri);
        RNVPAVDemuxer* d0 = [[RNVPAVDemuxer alloc] init];
        if (![d0 openAtURL:clip0URL error:&probeErr]) {
          teardown();
          const char* desc = probeErr.localizedDescription.UTF8String ?: "(nil)";
          throw std::runtime_error(
              std::string("VideoPipeline.render multi-transcode probe failed: ") +
              desc);
        }
        const NSInteger src0W = d0.width;
        const NSInteger src0H = d0.height;
        const double src0Fps = d0.fps > 0.0 ? d0.fps : 30.0;
        [d0 closeWithError:nullptr];

        NSInteger rot0 = -1;
        double crop0W = 0.0, crop0H = 0.0;
        if (baseClips[0].transform.has_value()) {
          const auto& t = *baseClips[0].transform;
          if (t.rotate.has_value()) rot0 = static_cast<NSInteger>(std::lround(*t.rotate));
          if (t.crop.has_value()) {
            crop0W = t.crop->w;
            crop0H = t.crop->h;
          }
        }
        const NSInteger content0W =
            crop0W > 0.0 ? static_cast<NSInteger>(std::lround(crop0W)) : src0W;
        const NSInteger content0H =
            crop0H > 0.0 ? static_cast<NSInteger>(std::lround(crop0H)) : src0H;
        const BOOL swap0 = (rot0 == 90 || rot0 == 270);
        const NSInteger outW =
            outputCopy.width.has_value()
                ? static_cast<NSInteger>(std::lround(*outputCopy.width))
                : (swap0 ? content0H : content0W);
        const NSInteger outH =
            outputCopy.height.has_value()
                ? static_cast<NSInteger>(std::lround(*outputCopy.height))
                : (swap0 ? content0W : content0H);
        const double fps =
            outputCopy.fps.has_value() ? *outputCopy.fps : src0Fps;
        const RNVPTranscodeCodec codec =
            outputCopy.codec.value_or(VideoCodec::H264) == VideoCodec::HEVC
                ? RNVPTranscodeCodecHEVC
                : RNVPTranscodeCodecH264;
        const NSInteger bitrate =
            outputCopy.bitrate.has_value()
                ? static_cast<NSInteger>(std::lround(*outputCopy.bitrate))
                : 0;

        // Transcode each clip to a temp, collecting concat sources.
        NSMutableArray<RNVPRemuxerConcatSource*>* sources =
            [NSMutableArray array];
        double cursor = 0.0;
        for (size_t i = 0; i < baseClips.size(); i++) {
          if (runnerToken.abortRequested) {
            teardown();
            throw makeCancelled();
          }
          // Fill a leading gap before this clip with a black + silent segment
          // (#18). The concat leaves silence for a video-only span, so the gap
          // is black + silent. fps is cosmetic for a static fill. On the overlap
          // path the crossfade composer renders black for empty timeline regions
          // itself, so no black temp is authored — each clip is positioned at its
          // true outputStart instead of the running concat cursor.
          const double gapSec =
              hasOverlap ? 0.0 : (baseClips[i].outputStart - cursor);
          if (gapSec > 1e-3) {
            NSString* gapPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"rnvp-mc-gap-%@-%zu.mp4",
                                               [[NSUUID UUID] UUIDString], i]];
            [temps addObject:gapPath];
            NSError* gErr = nil;
            if (!authorBlackClip(gapPath, outW, outH, fps, gapSec, runnerToken,
                                 &gErr)) {
              teardown();
              if (runnerToken.abortRequested) throw makeCancelled();
              const char* desc = gErr.localizedDescription.UTF8String ?: "(nil)";
              throw std::runtime_error(
                  std::string(
                      "VideoPipeline.render multi-transcode gap fill failed: ") +
                  desc);
            }
            // The black temp is authored >= gapSec; splice exactly gapSec so the
            // following clip lands precisely at its outputStart (no sub-frame
            // drift accumulating across gaps).
            [sources addObject:[[RNVPRemuxerConcatSource alloc]
                                   initWithSourceURL:[NSURL fileURLWithPath:gapPath]
                                         sourceStart:0.0
                                      sourceDuration:gapSec
                                         outputStart:cursor]];
            cursor = baseClips[i].outputStart;
          }
          NSURL* clipURL = urlFromUri(baseClips[i].uri);
          // Per-clip target fps: an explicit output.fps resamples every clip to
          // it; otherwise each clip keeps its OWN source cadence. Using clip[0]'s
          // fps for a clip recorded at a different rate would retime it (the
          // transcoder emits one output frame per decoded sample at
          // outputIndex/fps), changing its duration.
          double clipTargetFps = fps;
          if (!outputCopy.fps.has_value()) {
            RNVPAVDemuxer* di = [[RNVPAVDemuxer alloc] init];
            if ([di openAtURL:clipURL error:nil]) {
              if (di.fps > 0.0) clipTargetFps = di.fps;
              [di closeWithError:nullptr];
            }
          }
          NSString* tempPath = [NSTemporaryDirectory()
              stringByAppendingPathComponent:
                  [NSString stringWithFormat:@"rnvp-mc-%@-%zu.mp4",
                                             [[NSUUID UUID] UUIDString], i]];
          [temps addObject:tempPath];
          NSURL* tempURL = [NSURL fileURLWithPath:tempPath];
          RNVPTranscodeTarget* target = buildTranscodeTargetForClip(
              baseClips[i], outW, outH, clipTargetFps, codec, bitrate);
          NSError* tErr = nil;
          const BOOL ok = [RNVPTranscoder transcodeFromURL:clipURL
                                                     toURL:tempURL
                                                    target:target
                                                  overlays:nativeOverlays
                                                  metadata:nil
                                                 audioMode:perClipAudio
                                       audioReplacementURL:nil
                                                      stop:runnerToken
                                                  progress:nil
                                                     error:&tErr];
          if (!ok) {
            teardown();
            if (tErr != nil &&
                [tErr.domain isEqualToString:RNVPTranscoderErrorDomain] &&
                tErr.code == RNVPTranscoderErrorCodeCancelled) {
              throw makeCancelled();
            }
            const char* desc = tErr.localizedDescription.UTF8String ?: "(nil)";
            throw std::runtime_error(
                std::string("VideoPipeline.render multi-transcode clip[") +
                std::to_string(i) + "] failed: " + desc);
          }
          AVURLAsset* tempAsset = [AVURLAsset assetWithURL:tempURL];
          const double dur = CMTimeGetSeconds(tempAsset.duration);
          // Concat positions each clip at the running cursor; the crossfade
          // composer positions it at its true outputStart so overlaps land where
          // the timeline asks.
          const double clipOutputStart =
              hasOverlap ? baseClips[i].outputStart : cursor;
          [sources addObject:[[RNVPRemuxerConcatSource alloc]
                                 initWithSourceURL:tempURL
                                       sourceStart:0.0
                                    sourceDuration:dur
                                       outputStart:clipOutputStart]];
          cursor += dur;
        }

        // Join the base temps — a lossless concat for a contiguous/gapped
        // timeline, a crossfade re-encode for overlaps. Writes to the real
        // output, or to a base temp when overlay tracks still need layering.
        const CMTime frameDuration =
            CMTimeMake(1, static_cast<int32_t>(std::lround(fps)));
        NSError* cErr = nil;
        BOOL cok;
        if (hasOverlap) {
          cok = [RNVPRemuxer composeCrossfadeSources:sources
                                          renderSize:CGSizeMake(outW, outH)
                                       frameDuration:frameDuration
                                           audioMode:concatAudio
                                 audioReplacementURL:concatReplacementURL
                                               toURL:joinURL
                                                stop:runnerToken
                                               error:&cErr];
        } else {
          cok = [RNVPRemuxer remuxConcatSources:sources
                                          toURL:joinURL
                                      audioMode:concatAudio
                            audioReplacementURL:concatReplacementURL
                                           stop:runnerToken
                                          error:&cErr];
        }
        if (!cok) {
          teardown();
          if (cErr != nil &&
              [cErr.domain isEqualToString:RNVPRemuxerErrorDomain] &&
              cErr.code == RNVPRemuxerErrorCodeCancelled) {
            throw makeCancelled();
          }
          const char* desc = cErr.localizedDescription.UTF8String ?: "(nil)";
          throw std::runtime_error(
              std::string(
                  "VideoPipeline.render multi-transcode join failed: ") +
              desc);
        }

        // Composite overlay/PiP tracks (#17) on top of the joined base. Each
        // overlay clip transcodes to the shared output size (baking any per-clip
        // transform); the compositor then scales it into its normalized frame.
        if (hasOverlayTracks) {
          NSMutableArray<RNVPOverlayTrackSource*>* ovSources =
              [NSMutableArray array];
          for (size_t k = 0; k < overlayClips.size(); k++) {
            if (runnerToken.abortRequested) {
              teardown();
              throw makeCancelled();
            }
            const Clip& oc = overlayClips[k];
            NSString* ovTemp = [NSTemporaryDirectory()
                stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"rnvp-mt-ov-%@-%zu.mp4",
                                               [[NSUUID UUID] UUIDString], k]];
            [temps addObject:ovTemp];
            RNVPTranscodeTarget* ovTarget = buildTranscodeTargetForClip(
                oc, outW, outH, fps, codec, bitrate);
            NSError* ovErr = nil;
            if (![RNVPTranscoder transcodeFromURL:urlFromUri(oc.uri)
                                            toURL:[NSURL fileURLWithPath:ovTemp]
                                           target:ovTarget
                                         overlays:nil
                                         metadata:nil
                                        audioMode:RNVPAudioModeMute
                              audioReplacementURL:nil
                                             stop:runnerToken
                                         progress:nil
                                            error:&ovErr]) {
              teardown();
              if (runnerToken.abortRequested) throw makeCancelled();
              const char* desc = ovErr.localizedDescription.UTF8String ?: "(nil)";
              throw std::runtime_error(
                  std::string("VideoPipeline.render overlay transcode failed: ") +
                  desc);
            }
            CGRect frame = CGRectMake(0, 0, 1, 1);
            if (oc.frame.has_value()) {
              frame = CGRectMake(oc.frame->x, oc.frame->y, oc.frame->w,
                                 oc.frame->h);
            }
            [ovSources addObject:[[RNVPOverlayTrackSource alloc]
                                     initWithSourceURL:[NSURL fileURLWithPath:ovTemp]
                                           sourceStart:0.0
                                        sourceDuration:oc.sourceDuration
                                           outputStart:oc.outputStart
                                                 frame:frame
                                                zOrder:static_cast<NSInteger>(
                                                           oc.track.value_or(0.0))]];
          }
          NSError* mtErr = nil;
          if (![RNVPRemuxer composeOverlayTracks:joinURL
                                  overlaySources:ovSources
                                      renderSize:CGSizeMake(outW, outH)
                                   frameDuration:frameDuration
                                           toURL:outputURL
                                            stop:runnerToken
                                           error:&mtErr]) {
            teardown();
            if (mtErr != nil &&
                [mtErr.domain isEqualToString:RNVPRemuxerErrorDomain] &&
                mtErr.code == RNVPRemuxerErrorCodeCancelled) {
              throw makeCancelled();
            }
            const char* desc = mtErr.localizedDescription.UTF8String ?: "(nil)";
            throw std::runtime_error(
                std::string("VideoPipeline.render overlay composite failed: ") +
                desc);
          }
        }
        teardown();
      });
    }

    // Fast remux path: single-clip rotation/flip-only (optionally windowed).
    // preferredTransform carries the rotation/flip and the composition carries
    // the trim window — no pixels are re-encoded, so trim + flip stays as cheap
    // as a plain trim.
    if (single && !hasOverlayTracks && clipHasRotateOrFlip((*spec.clips)[0])) {
      const auto& clip = (*spec.clips)[0];
      NSInteger rotate = -1;
      BOOL flipH = NO;
      BOOL flipV = NO;
      if (clip.transform.has_value()) {
        const auto& t = *clip.transform;
        if (t.rotate.has_value()) {
          rotate = static_cast<NSInteger>(std::lround(*t.rotate));
        }
        flipH = t.flipH.value_or(false) ? YES : NO;
        flipV = t.flipV.value_or(false) ? YES : NO;
      }
      NSURL* clipURL = urlFromUri(clip.uri);
      NSURL* outputURLTransform = urlFromUri(spec.output.path);
      const double startSec = clip.sourceStart;
      const double durationSec = clip.sourceDuration;
      const ResolvedAudio resolvedAudio = resolveAudio(spec);
      const RNVPAudioMode audioMode = resolvedAudio.mode;
      NSURL* audioReplacementURL = resolvedAudio.replacementURL;

      const std::string transformTokenCopy = renderToken;
      std::shared_ptr<StopToken> transformStop =
          !renderToken.empty()
              ? RenderTokenRegistry::registerToken(renderToken)
              : std::make_shared<StopToken>();
      RNVPStopToken* transformRunnerToken =
          [RNVPStopToken tokenFromSharedPtr:transformStop];
      NSString* transformJournalToken =
          !renderToken.empty()
              ? [NSString stringWithUTF8String:renderToken.c_str()]
              : internalJournalToken("render-transform");
      // Bare path for journal/zombie-cleanup consistency (#74).
      NSString* transformOutputPath = outputFilesystemPath(spec.output.path);
      RNVPBackgroundTaskGuard* transformGuard =
          [RNVPBackgroundTaskGuard beginWithTokenId:transformJournalToken
                                         outputPath:transformOutputPath
                                          stopToken:transformRunnerToken];
      return Promise<void>::async(
          [clipURL, outputURLTransform, startSec, durationSec, rotate, flipH,
           flipV, audioMode, audioReplacementURL, transformTokenCopy,
           transformGuard]() {
        NSError* err = nil;
        const BOOL ok = [RNVPRemuxer remuxTransformFromURL:clipURL
                                                     toURL:outputURLTransform
                                                  startSec:startSec
                                               durationSec:durationSec
                                                    rotate:rotate
                                                     flipH:flipH
                                                     flipV:flipV
                                                 audioMode:audioMode
                                       audioReplacementURL:audioReplacementURL
                                                     error:&err];
        RenderTokenRegistry::unregisterToken(transformTokenCopy);
        [transformGuard end];
        if (!ok) {
          const char* desc = err.localizedDescription.UTF8String ?: "(nil)";
          throw std::runtime_error(std::string("VideoPipeline.render "
                                                "transform remux failed: ") +
                                   desc);
        }
      });
    }

    if (auto rejection = describeConcatBranchRejection(spec);
        rejection.has_value()) {
      return Promise<void>::rejected(
          std::make_exception_ptr(makeInvalidSpec(*rejection)));
    }

    // Bare path for journal/zombie-cleanup consistency (#74).
    NSString* outputPathConcat = outputFilesystemPath(spec.output.path);
    NSURL* outputURLConcat = urlFromUri(spec.output.path);

    NSMutableArray<RNVPRemuxerConcatSource*>* sources =
        [NSMutableArray arrayWithCapacity:spec.clips->size()];
    for (const auto& clip : *spec.clips) {
      NSURL* clipURL = urlFromUri(clip.uri);
      [sources addObject:[[RNVPRemuxerConcatSource alloc]
                             initWithSourceURL:clipURL
                                   sourceStart:clip.sourceStart
                                sourceDuration:clip.sourceDuration
                                   outputStart:clip.outputStart]];
    }
    const ResolvedAudio concatAudio = resolveAudio(spec);
    const RNVPAudioMode concatAudioMode = concatAudio.mode;
    NSURL* concatAudioReplacementURL = concatAudio.replacementURL;
    const std::string concatTokenCopy = renderToken;
    std::shared_ptr<StopToken> concatStop =
        !renderToken.empty()
            ? RenderTokenRegistry::registerToken(renderToken)
            : std::make_shared<StopToken>();
    RNVPStopToken* concatRunnerToken =
        [RNVPStopToken tokenFromSharedPtr:concatStop];

    NSString* concatJournalToken =
        !renderToken.empty()
            ? [NSString stringWithUTF8String:renderToken.c_str()]
            : internalJournalToken("render-concat");
    RNVPBackgroundTaskGuard* concatGuard =
        [RNVPBackgroundTaskGuard beginWithTokenId:concatJournalToken
                                       outputPath:outputPathConcat
                                        stopToken:concatRunnerToken];

    return Promise<void>::async(
        [sources, outputURLConcat, concatAudioMode, concatAudioReplacementURL,
         concatRunnerToken, concatTokenCopy, concatGuard]() {
      NSError* err = nil;
      const BOOL ok = [RNVPRemuxer remuxConcatSources:sources
                                                toURL:outputURLConcat
                                            audioMode:concatAudioMode
                                  audioReplacementURL:concatAudioReplacementURL
                                                 stop:concatRunnerToken
                                                error:&err];
      RenderTokenRegistry::unregisterToken(concatTokenCopy);
      [concatGuard end];
      if (!ok) {
        if (err != nil && [err.domain isEqualToString:RNVPRemuxerErrorDomain] &&
            err.code == RNVPRemuxerErrorCodeCancelled) {
          throw makeCancelled();
        }
        const char* desc = err.localizedDescription.UTF8String ?: "(nil)";
        throw std::runtime_error(std::string("VideoPipeline.render concat "
                                              "failed: ") +
                                 desc);
      }
    });
  }

  if (auto rejection = describeSynthesizeRejection(spec); rejection.has_value()) {
    return Promise<void>::rejected(
        std::make_exception_ptr(makeInvalidSpec(*rejection)));
  }

  // Accept a bare path or a `file://` URI for output.path (issue #74).
  NSString* outputPath = outputFilesystemPath(spec.output.path);
  const NSInteger width = static_cast<NSInteger>(std::lround(*spec.output.width));
  const NSInteger height = static_cast<NSInteger>(std::lround(*spec.output.height));
  const double fps = *spec.output.fps;

  const bool isOpen = std::holds_alternative<OpenDuration>(*spec.duration);

  if (!isOpen) {
    const double seconds = std::get<FixedDuration>(*spec.duration).seconds;
    RNVPProgressBlock progressBlock = progressBlockFromNitro(onProgress);
    const std::string fixedTokenCopy = renderToken;
    std::shared_ptr<StopToken> fixedStop =
        !renderToken.empty()
            ? RenderTokenRegistry::registerToken(renderToken)
            : std::make_shared<StopToken>();
    RNVPStopToken* fixedRunnerToken =
        [RNVPStopToken tokenFromSharedPtr:fixedStop];
    NSString* fixedJournalToken =
        !renderToken.empty()
            ? [NSString stringWithUTF8String:renderToken.c_str()]
            : internalJournalToken("render-synth-fixed");
    RNVPBackgroundTaskGuard* fixedGuard =
        [RNVPBackgroundTaskGuard beginWithTokenId:fixedJournalToken
                                       outputPath:outputPath
                                        stopToken:fixedRunnerToken];
    return Promise<void>::async(
        [outputPath, width, height, fps, seconds, fixedRunnerToken,
         fixedTokenCopy, progressBlock, fixedGuard]() {
      NSError* err = nil;
      BOOL aborted = NO;
      const BOOL ok =
          [RNVPSynthesizeRunner runFixedWithOutputPath:outputPath
                                                 width:width
                                                height:height
                                                   fps:fps
                                               seconds:seconds
                                             stopToken:fixedRunnerToken
                                              progress:progressBlock
                                               aborted:&aborted
                                                 error:&err];
      RenderTokenRegistry::unregisterToken(fixedTokenCopy);
      [fixedGuard end];
      if (!ok) {
        const char* desc = err.localizedDescription.UTF8String ?: "(nil)";
        throw std::runtime_error(std::string("VideoPipeline.render synthesize "
                                              "failed: ") +
                                 desc);
      }
      if (aborted) throw makeCancelled();
    });
  }

  const auto& open = std::get<OpenDuration>(*spec.duration);
  const double maxSeconds = open.maxSeconds.has_value() ? *open.maxSeconds : 0.0;

  // Register the token BEFORE dispatching to the pool — otherwise a
  // cancelRender / finishRender call that races the background thread could
  // miss the registration and silently no-op. Empty token ⇒ caller opted out
  // of cancellation; we still allocate a local StopToken so the loop compiles
  // through the same code path.
  const std::string tokenCopy = renderToken;
  std::shared_ptr<StopToken> stop =
      !renderToken.empty() ? RenderTokenRegistry::registerToken(renderToken)
                           : std::make_shared<StopToken>();

  // RNVPStopToken wraps the same shared_ptr<StopToken> that the registry
  // holds, so a cancelRender from JS flips the exact flags the loop polls.
  RNVPStopToken* runnerToken = [RNVPStopToken tokenFromSharedPtr:stop];

  RNVPProgressBlock openProgressBlock = progressBlockFromNitro(onProgress);
  NSString* openJournalToken =
      !renderToken.empty()
          ? [NSString stringWithUTF8String:renderToken.c_str()]
          : internalJournalToken("render-synth-open");
  RNVPBackgroundTaskGuard* openGuard =
      [RNVPBackgroundTaskGuard beginWithTokenId:openJournalToken
                                     outputPath:outputPath
                                      stopToken:runnerToken];
  return Promise<void>::async(
      [outputPath, width, height, fps, maxSeconds, runnerToken, tokenCopy,
       openProgressBlock, openGuard]() {
        NSError* err = nil;
        NSInteger framesWritten = 0;
        BOOL aborted = NO;
        const BOOL ok =
            [RNVPSynthesizeRunner runOpenWithOutputPath:outputPath
                                                  width:width
                                                 height:height
                                                    fps:fps
                                             maxSeconds:maxSeconds
                                              stopToken:runnerToken
                                          finishOnFrame:-1
                                               progress:openProgressBlock
                                          framesWritten:&framesWritten
                                                aborted:&aborted
                                                  error:&err];
        // Always release the registry entry — the token is single-use.
        RenderTokenRegistry::unregisterToken(tokenCopy);
        [openGuard end];
        if (!ok) {
          const char* desc = err.localizedDescription.UTF8String ?: "(nil)";
          throw std::runtime_error(std::string("VideoPipeline.render synthesize "
                                                "failed: ") +
                                   desc);
        }
        if (aborted) {
          // JS treats the abort path as a rejection (`CancelledError`); the
          // wrapper in src/video.ts already surfaces it that way when the
          // signal fires, but a controller.abort() from JS must also
          // reject the render promise so the caller's try/catch fires.
          throw makeCancelled();
        }
      });
}

void HybridVideoPipeline::cancelRender(const std::string& renderToken) {
  if (renderToken.empty()) return;
  if (auto stop = RenderTokenRegistry::lookup(renderToken)) {
    stop->requestAbort();
  }
  // Unknown token — render already finished / never started. Idempotent.
}

void HybridVideoPipeline::finishRender(const std::string& renderToken) {
  if (renderToken.empty()) return;
  if (auto stop = RenderTokenRegistry::lookup(renderToken)) {
    stop->requestFinish();
  }
}

// --- Convenience wrappers --------------------------------------------------

std::shared_ptr<Promise<void>> HybridVideoPipeline::trim(
    const std::string& uri,
    const std::string& outPath,
    double startSec,
    double durationSec,
    const std::string& /*renderToken*/,
    const std::optional<std::function<void(const Progress&)>>& /*onProgress*/) {
  // `trim` is the lossless-cut primitive: pure passthrough remux, no
  // transform. Trimming *and* transforming in one pass goes through
  // `render`, whose native router picks remux (rotation-only) vs transcode
  // (flip/crop). Remux trim has no decode/encode loop to instrument, so
  // `onProgress` is accepted for API uniformity and ignored — see
  // `docs/api.md` (Progress reporting on convenience methods).
  NSURL* sourceURL = urlFromUri(uri);
  NSURL* outputURL = urlFromUri(outPath);
  return Promise<void>::async(
      [sourceURL, outputURL, startSec, durationSec]() {
        NSError* err = nil;
        const BOOL ok = [RNVPRemuxer remuxTrimFromURL:sourceURL
                                                toURL:outputURL
                                             startSec:startSec
                                          durationSec:durationSec
                                                error:&err];
        if (!ok) {
          const char* desc = err.localizedDescription.UTF8String ?: "(nil)";
          throw std::runtime_error(std::string("VideoPipeline.trim failed: ") +
                                   desc);
        }
      });
}

std::shared_ptr<Promise<void>> HybridVideoPipeline::flip(
    const std::string& uri,
    const std::string& outPath,
    FlipAxis axis,
    const std::string& /*renderToken*/,
    const std::optional<std::function<void(const Progress&)>>& /*onProgress*/) {
  // iOS flip is a rotation-flag remux (mp4 ↔ mov) — no decode/encode, no
  // progress to report. Accepted for API uniformity; ignored.
  NSURL* sourceURL = urlFromUri(uri);
  NSURL* outputURL = urlFromUri(outPath);
  const RNVPFlipAxis nsAxis = (axis == FlipAxis::VERTICAL)
                                  ? RNVPFlipAxisVertical
                                  : RNVPFlipAxisHorizontal;
  return Promise<void>::async([sourceURL, outputURL, nsAxis]() {
    NSError* err = nil;
    const BOOL ok = [RNVPRemuxer remuxFlipFromURL:sourceURL
                                            toURL:outputURL
                                             axis:nsAxis
                                            error:&err];
    if (!ok) {
      const char* desc = err.localizedDescription.UTF8String ?: "(nil)";
      throw std::runtime_error(std::string("VideoPipeline.flip failed: ") +
                               desc);
    }
  });
}

std::shared_ptr<Promise<void>> HybridVideoPipeline::stamp(
    const std::string& uri,
    const std::string& outPath,
    const std::optional<std::variant<ImageOverlay, TextOverlay>>& watermark,
    const std::optional<MetadataSpec>& metadata,
    const std::string& /*renderToken*/,
    const std::optional<std::function<void(const Progress&)>>& onProgress) {
  RNVPStampMetadata* stampMetadata = buildStampMetadata(metadata);
  NSURL* sourceURL = urlFromUri(uri);
  NSURL* outputURL = urlFromUri(outPath);

  drainZombiesOnce();
  // Bare path so the stamp journal's zombie cleanup (fileExistsAtPath: /
  // removeItemAtPath:) matches the file urlFromUri(outPath) writes — outPath
  // may be a file:// URI (#74).
  NSString* stampOutputPath = outputFilesystemPath(outPath);

  // Metadata-only → passthrough remux (T032). Cheaper than a re-encode, and
  // preserves codec/bitrate/HDR/color primaries byte-for-byte.
  if (!watermark.has_value()) {
    RNVPBackgroundTaskGuard* stampGuard = [RNVPBackgroundTaskGuard
        beginWithTokenId:internalJournalToken("stamp-remux")
              outputPath:stampOutputPath
               stopToken:nil];
    return Promise<void>::async(
        [sourceURL, outputURL, stampMetadata, stampGuard]() {
      NSError* err = nil;
      const BOOL ok = [RNVPRemuxer remuxStampFromURL:sourceURL
                                               toURL:outputURL
                                            metadata:stampMetadata
                                               error:&err];
      [stampGuard end];
      if (!ok) {
        const char* desc = err.localizedDescription.UTF8String ?: "(nil)";
        throw std::runtime_error(std::string("VideoPipeline.stamp failed: ") +
                                 desc);
      }
    });
  }

  // Watermark present → @c RNVPExportSessionStamp, a thin facade that
  // builds an @c RNVPOverlayRenderer from the supplied overlays and hands
  // a composer block to @c RNVPExportSession (the generic
  // AVAssetExportSession-backed driver shared by compose / render too).
  NSMutableArray* nativeOverlays =
      [NSMutableArray arrayWithCapacity:1];
  appendNativeOverlay(nativeOverlays, *watermark);

  RNVPExportSessionProgress stampProgressBlock =
      exportSessionProgressFromNitro(onProgress);

  RNVPBackgroundTaskGuard* stampTranscodeGuard = [RNVPBackgroundTaskGuard
      beginWithTokenId:internalJournalToken("stamp-export-session")
            outputPath:stampOutputPath
             stopToken:nil];
  return Promise<void>::async(
      [sourceURL, outputURL, nativeOverlays, stampMetadata,
       stampTranscodeGuard, stampProgressBlock]() {
    NSError* err = nil;
    const BOOL ok = [RNVPExportSessionStamp stampFromURL:sourceURL
                                                   toURL:outputURL
                                                overlays:nativeOverlays
                                                metadata:stampMetadata
                                                progress:stampProgressBlock
                                                   error:&err];
    [stampTranscodeGuard end];
    if (!ok) {
      const char* desc = err.localizedDescription.UTF8String ?: "(nil)";
      throw std::runtime_error(std::string("VideoPipeline.stamp failed: ") +
                               desc);
    }
  });
}

// --- renderCompose — compose-on-clip via RNVPExportSession; null-input via
// --- RNVPAVMuxer (no source asset for AVAssetExportSession to consume).

std::shared_ptr<Promise<void>> HybridVideoPipeline::renderCompose(
    const VideoSpec& spec,
    const std::string& renderToken,
    const std::function<std::shared_ptr<Promise<bool>>(
        const std::shared_ptr<HybridFrameTargetSpec>&,
        const std::optional<std::shared_ptr<HybridFrameSourceSpec>>&,
        double, double)>& drawFrame,
    const std::optional<std::function<void(const Progress&)>>& onProgress) {
  drainZombiesOnce();

  // Two branches:
  //   1. Synthesize (no clips) — caller draws every pixel; output dimensions
  //      and frame count come from spec.output + spec.duration.
  //   2. Compose-on-clip (one or more clips) — pump decodes the source video
  //      frame-by-frame into BGRA pixel buffers, hands each to the worklet
  //      as `source`, the worklet draws on top, the result is written.
  //      Output dimensions / FPS / PTS all follow the source.
  const bool isSynthesized =
      !spec.clips.has_value() || spec.clips->empty();

  if (!isSynthesized && spec.clips->size() > 1) {
    return Promise<void>::rejected(std::make_exception_ptr(makeInvalidSpec(
        "VideoPipeline.renderCompose: InvalidSpec — multi-clip compose is "
        "not yet implemented; pass exactly one clip")));
  }

  if (isSynthesized && (!spec.duration.has_value() ||
                        !std::holds_alternative<FixedDuration>(*spec.duration))) {
    return Promise<void>::rejected(std::make_exception_ptr(makeInvalidSpec(
        "VideoPipeline.renderCompose: InvalidSpec — only fixed-duration "
        "synthesize is supported in this slice")));
  }
  if (isSynthesized &&
      (!spec.output.width.has_value() || !spec.output.height.has_value() ||
       !spec.output.fps.has_value() || *spec.output.width <= 0.0 ||
       *spec.output.height <= 0.0 || *spec.output.fps <= 0.0)) {
    return Promise<void>::rejected(std::make_exception_ptr(makeInvalidSpec(
        "VideoPipeline.renderCompose: InvalidSpec — synthesize requires "
        "output.width, output.height, output.fps")));
  }

  const std::string outputPath = spec.output.path;
  const std::string clipUri =
      isSynthesized ? std::string{} : spec.clips->front().uri;

  // For synthesize: width/height/fps come from the spec.
  // For compose-on-clip: read from the source after we open the demuxer.
  const int specWidth =
      isSynthesized ? static_cast<int>(*spec.output.width) : 0;
  const int specHeight =
      isSynthesized ? static_cast<int>(*spec.output.height) : 0;
  const double specFps = isSynthesized ? *spec.output.fps : 0.0;
  const double specSeconds =
      isSynthesized ? std::get<FixedDuration>(*spec.duration).seconds : 0.0;

  const std::string tokenCopy = renderToken;
  std::shared_ptr<StopToken> stop =
      !renderToken.empty() ? RenderTokenRegistry::registerToken(renderToken)
                           : std::make_shared<StopToken>();

  auto drawFrameCopy = drawFrame;
  auto onProgressCopy = onProgress;
  // Resolve spec.metadata into the same RNVPStampMetadata shape the
  // stamp/transcode paths use, so renderCompose composes with the rest of
  // the metadata story instead of inventing a parallel pass-through.
  RNVPStampMetadata* stampMetadata = buildStampMetadata(spec.metadata);

  // Compose-on-clip carries the source clip's audio through the export driver;
  // honour spec.audio (mute drops it, replace swaps it). Synthesize has no
  // source audio, so the directive is a no-op there.
  const ResolvedAudio resolvedAudio = resolveAudio(spec);
  const RNVPAudioMode audioMode = resolvedAudio.mode;
  NSURL* audioReplacementURL = resolvedAudio.replacementURL;

  return Promise<void>::async([isSynthesized, specWidth, specHeight, specFps,
                               specSeconds, outputPath, clipUri,
                               drawFrameCopy, onProgressCopy, stop,
                               tokenCopy, stampMetadata, audioMode,
                               audioReplacementURL]() {
    // Accept a bare path or a `file://` URI for output.path (issue #74); the
    // muxer / fileExistsAtPath / fileURLWithPath below all want a bare path.
    NSString* outputPathNS = outputFilesystemPath(outputPath);
    NSFileManager* fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:outputPathNS]) {
      [fm removeItemAtPath:outputPathNS error:NULL];
    }

    // ===================================================================
    // Compose-on-clip branch — route through @c RNVPExportSession.
    // The driver owns AVAssetExportSession, encoder pacing, audio
    // passthrough, and the encoder pipeline. We supply a composer block
    // that materializes the CIImage frame into a CVPixelBuffer (for the JS
    // worklet to read), allocates a target CVPixelBuffer (for the JS to
    // write into), and wraps the result back as a CIImage for the encoder.
    // ===================================================================
    if (!isSynthesized) {
      NSString* clipUriNS =
          [NSString stringWithUTF8String:clipUri.c_str()] ?: @"";
      NSURL* sourceURL = [clipUriNS hasPrefix:@"file://"]
                            ? [NSURL URLWithString:clipUriNS]
                            : [NSURL fileURLWithPath:clipUriNS];

      // Probe the source for the canvas size so per-frame buffer allocations
      // can be sized correctly. The driver itself does the same probe
      // internally, but we need it here for the per-frame allocations.
      AVURLAsset* composeAsset = [AVURLAsset assetWithURL:sourceURL];
      AVAssetTrack* composeVideoTrack =
          [composeAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
      if (composeVideoTrack == nil) {
        RenderTokenRegistry::unregisterToken(tokenCopy);
        throw std::runtime_error(
            "VideoPipeline.renderCompose: clip has no video track");
      }
      const CGSize composeNatural = composeVideoTrack.naturalSize;
      const CGSize composeApplied =
          CGSizeApplyAffineTransform(composeNatural,
                                      composeVideoTrack.preferredTransform);
      const NSInteger canvasW =
          static_cast<NSInteger>(std::llround(std::fabs(composeApplied.width)));
      const NSInteger canvasH =
          static_cast<NSInteger>(std::llround(std::fabs(composeApplied.height)));

      RNVPStopToken* runnerToken =
          stop ? [RNVPStopToken tokenFromSharedPtr:stop] : nil;
      const auto t0 = std::chrono::steady_clock::now();

      // CIContext lives for the duration of the export — re-creating it per
      // frame would burn Metal setup cost every call.
      CIContext* ciContext = [CIContext contextWithOptions:nil];
      NSDictionary<NSString*, id>* pbAttrs = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey :
            @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferWidthKey : @(canvasW),
        (NSString*)kCVPixelBufferHeightKey : @(canvasH),
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
      };

      RNVPExportSessionComposer composer =
          ^CIImage*(CIImage* source, CMTime t, int32_t i) {
            // Materialize the source CIImage into a CVPixelBuffer the JS
            // worklet can read (HybridFrameSource wraps a CVPixelBuffer).
            CVPixelBufferRef sourcePb = NULL;
            const CVReturn cvSrc = CVPixelBufferCreate(
                kCFAllocatorDefault, (size_t)canvasW, (size_t)canvasH,
                kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pbAttrs,
                &sourcePb);
            if (cvSrc != kCVReturnSuccess || sourcePb == NULL) {
              @throw [NSException
                  exceptionWithName:@"RNVPComposeWorklet"
                             reason:[NSString stringWithFormat:
                                                   @"CVPixelBufferCreate(source)"
                                                   @" failed (cv=%d)",
                                                   (int)cvSrc]
                           userInfo:nil];
            }
            [ciContext render:source
                toCVPixelBuffer:sourcePb
                         bounds:CGRectMake(0, 0, canvasW, canvasH)
                     colorSpace:nil];

            // Allocate a destination buffer the JS worklet can write to.
            CVPixelBufferRef targetPb = NULL;
            const CVReturn cvDst = CVPixelBufferCreate(
                kCFAllocatorDefault, (size_t)canvasW, (size_t)canvasH,
                kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pbAttrs,
                &targetPb);
            if (cvDst != kCVReturnSuccess || targetPb == NULL) {
              CVPixelBufferRelease(sourcePb);
              @throw [NSException
                  exceptionWithName:@"RNVPComposeWorklet"
                             reason:[NSString stringWithFormat:
                                                   @"CVPixelBufferCreate(target)"
                                                   @" failed (cv=%d)",
                                                   (int)cvDst]
                           userInfo:nil];
            }

            auto target = std::make_shared<HybridFrameTarget>(
                targetPb, PixelFormat::BGRA8888);
            auto sourceWrapper = std::make_shared<HybridFrameSource>(
                sourcePb, PixelFormat::BGRA8888);
            auto sourceArg =
                std::optional<std::shared_ptr<HybridFrameSourceSpec>>(
                    std::static_pointer_cast<HybridFrameSourceSpec>(
                        sourceWrapper));

            NSException* threw = nil;
            try {
              auto promise = drawFrameCopy(target, sourceArg,
                                            static_cast<double>(i),
                                            CMTimeGetSeconds(t));
              promise->await().get();
            } catch (const std::exception& e) {
              threw = [NSException
                  exceptionWithName:@"RNVPComposeWorklet"
                             reason:[NSString stringWithFormat:
                                                   @"drawFrame threw at frame "
                                                   @"%d: %s",
                                                   i, e.what()]
                           userInfo:nil];
            }
            target->invalidate();
            sourceWrapper->invalidate();

            CIImage* output =
                [CIImage imageWithCVPixelBuffer:targetPb];
            CVPixelBufferRelease(sourcePb);
            CVPixelBufferRelease(targetPb);
            if (threw != nil) {
              @throw threw;
            }
            return output;
          };

      // Translate the driver's per-frame progress callback into the
      // existing C++ @c Progress shape so consumers see the same fields
      // regardless of which driver runs underneath.
      RNVPExportSessionProgress progressBlock = nil;
      if (onProgressCopy.has_value()) {
        progressBlock =
            ^(int32_t framesCompleted, int32_t nbFrames) {
              const auto elapsed = std::chrono::steady_clock::now() - t0;
              const double elapsedMs =
                  std::chrono::duration<double, std::milli>(elapsed).count();
              const double etaMs =
                  framesCompleted > 0 && nbFrames > framesCompleted
                      ? elapsedMs *
                            static_cast<double>(nbFrames - framesCompleted) /
                            static_cast<double>(framesCompleted)
                      : 0.0;
              Progress p(static_cast<double>(framesCompleted),
                         nbFrames > 0
                             ? std::optional<double>(
                                   static_cast<double>(nbFrames))
                             : std::optional<double>(),
                         elapsedMs, std::optional<double>(etaMs));
              (*onProgressCopy)(p);
              if (framesCompleted % 50 == 0 ||
                  (nbFrames > 0 && framesCompleted == nbFrames)) {
                if (nbFrames > 0) {
                  NSLog(@"[RNVP.renderCompose] %d/%d frames in %.0fms "
                        @"(%.1fms/frame)",
                        framesCompleted, nbFrames, elapsedMs,
                        elapsedMs / static_cast<double>(framesCompleted));
                } else {
                  NSLog(@"[RNVP.renderCompose] %d frames in %.0fms "
                        @"(%.1fms/frame)",
                        framesCompleted, elapsedMs,
                        elapsedMs / static_cast<double>(framesCompleted));
                }
              }
            };
      }

      // Pre-merge stamp metadata over the source's container metadata before
      // building the request — RNVPExportRequest is format-agnostic and takes
      // an already-merged AVMetadataItem array.
      NSArray<AVMetadataItem*>* mergedMetadata = nil;
      if (stampMetadata != nil) {
        AVURLAsset* metaAsset = [AVURLAsset assetWithURL:sourceURL];
        mergedMetadata =
            [stampMetadata mergedWithSourceMetadata:metaAsset.metadata];
      }
      RNVPExportRequest* request = [[RNVPExportRequest alloc]
          initWithSource:sourceURL
                  output:[NSURL fileURLWithPath:outputPathNS]
               timeRange:kCMTimeRangeInvalid
                metadata:mergedMetadata
                composer:composer
               audioMode:audioMode
     audioReplacementURL:audioReplacementURL
                    stop:runnerToken
                progress:progressBlock];
      NSError* err = nil;
      const BOOL ok = [RNVPExportSession runRequest:request error:&err];
      RenderTokenRegistry::unregisterToken(tokenCopy);
      if (!ok) {
        if (runnerToken != nil && runnerToken.abortRequested) {
          throw std::runtime_error("VideoPipeline.renderCompose: Cancelled");
        }
        const char* desc = err.localizedDescription.UTF8String ?: "(nil)";
        throw std::runtime_error(
            std::string("VideoPipeline.renderCompose: ") + desc);
      }
      return;
    }

    // ===================================================================
    // Null-input synthesize branch — stays on @c RNVPAVMuxer because
    // AVAssetExportSession requires a source asset and we have none.
    // ===================================================================
    NSArray<AVMetadataItem*>* sourceMetadata = nil;
    if (stampMetadata != nil) {
      sourceMetadata = [stampMetadata mergedWithSourceMetadata:nil];
    }

    const int width = specWidth;
    const int height = specHeight;
    const double fps = specFps;
    const int nbFrames =
        static_cast<int>(std::llround(specFps * specSeconds));

    RNVPAVMuxer* muxer = [[RNVPAVMuxer alloc] init];
    NSError* openErr = nil;
    const BOOL opened = [muxer openVideoOnlyAtPath:outputPathNS
                                             width:width
                                            height:height
                                               fps:(NSInteger)std::llround(fps)
                                          metadata:sourceMetadata
                                             error:&openErr];
    if (!opened) {
      RenderTokenRegistry::unregisterToken(tokenCopy);
      const char* desc = openErr.localizedDescription.UTF8String ?: "(nil)";
      throw std::runtime_error(
          std::string("VideoPipeline.renderCompose: muxer.open failed: ") +
          desc);
    }

    NSDictionary<NSString*, id>* pbAttrs = @{
      (NSString*)kCVPixelBufferPixelFormatTypeKey :
          @(kCVPixelFormatType_32BGRA),
      (NSString*)kCVPixelBufferWidthKey : @(width),
      (NSString*)kCVPixelBufferHeightKey : @(height),
      (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };

    bool aborted = false;
    NSError* failure = nil;
    const auto t0 = std::chrono::steady_clock::now();
    int frameIndex = 0;

    while (frameIndex < nbFrames) {
      if (stop && stop->abortRequested()) {
        aborted = true;
        break;
      }

      CVPixelBufferRef destPb = NULL;
      CVReturn cv = CVPixelBufferCreate(
          kCFAllocatorDefault, (size_t)width, (size_t)height,
          kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pbAttrs, &destPb);
      if (cv != kCVReturnSuccess || destPb == NULL) {
        failure = [NSError
            errorWithDomain:@"VideoPipeline"
                       code:0
                   userInfo:@{
                     NSLocalizedDescriptionKey :
                         [NSString stringWithFormat:
                                       @"CVPixelBufferCreate failed (cv=%d)",
                                       (int)cv]
                   }];
        break;
      }

      auto target =
          std::make_shared<HybridFrameTarget>(destPb, PixelFormat::BGRA8888);
      const double timeSec = static_cast<double>(frameIndex) / fps;

      try {
        auto promise = drawFrameCopy(target, std::nullopt,
                                      static_cast<double>(frameIndex),
                                      timeSec);
        promise->await().get();
      } catch (const std::exception& e) {
        target->invalidate();
        CVPixelBufferRelease(destPb);
        char msg[512];
        std::snprintf(msg, sizeof(msg),
                      "drawFrame threw at frame %d: %s", frameIndex, e.what());
        failure = [NSError errorWithDomain:@"VideoPipeline"
                                      code:0
                                  userInfo:@{
                                    NSLocalizedDescriptionKey :
                                        [NSString stringWithUTF8String:msg]
                                  }];
        break;
      }
      target->invalidate();

      const CMTime pts = CMTimeMake(
          static_cast<int64_t>(std::llround(timeSec * 1'000'000'000.0)),
          1'000'000'000);
      NSError* appendErr = nil;
      const BOOL appended = [muxer appendPixelBuffer:destPb
                                    presentationTime:pts
                                               error:&appendErr];
      CVPixelBufferRelease(destPb);
      if (!appended) {
        failure = appendErr;
        break;
      }

      if (onProgressCopy.has_value()) {
        const auto elapsed = std::chrono::steady_clock::now() - t0;
        const double elapsedMs =
            std::chrono::duration<double, std::milli>(elapsed).count();
        const double etaMs = nbFrames > 0
                                 ? elapsedMs *
                                       static_cast<double>(nbFrames -
                                                           frameIndex - 1) /
                                       static_cast<double>(frameIndex + 1)
                                 : 0.0;
        Progress p(static_cast<double>(frameIndex + 1),
                   std::optional<double>(static_cast<double>(nbFrames)),
                   elapsedMs, std::optional<double>(etaMs));
        (*onProgressCopy)(p);
      }

      frameIndex++;
      if (frameIndex % 50 == 0 || frameIndex == nbFrames) {
        const auto elapsed = std::chrono::steady_clock::now() - t0;
        const double elapsedMs =
            std::chrono::duration<double, std::milli>(elapsed).count();
        NSLog(@"[RNVP.renderCompose] synth %d/%d frames in %.0fms "
              @"(%.1fms/frame)",
              frameIndex, nbFrames, elapsedMs,
              elapsedMs / static_cast<double>(frameIndex));
      }
    }

    NSError* closeErr = nil;
    [muxer closeWithError:&closeErr];
    RenderTokenRegistry::unregisterToken(tokenCopy);

    if (aborted) {
      [fm removeItemAtPath:outputPathNS error:NULL];
      throw std::runtime_error("VideoPipeline.renderCompose: Cancelled");
    }
    if (failure != nil) {
      [fm removeItemAtPath:outputPathNS error:NULL];
      const char* desc = failure.localizedDescription.UTF8String ?: "(nil)";
      throw std::runtime_error(std::string("VideoPipeline.renderCompose: ") +
                               desc);
    }
    if (closeErr != nil) {
      const char* desc = closeErr.localizedDescription.UTF8String ?: "(nil)";
      throw std::runtime_error(
          std::string("VideoPipeline.renderCompose: muxer.close failed: ") +
          desc);
    }
  });
}

} // namespace margelo::nitro::videopipeline
