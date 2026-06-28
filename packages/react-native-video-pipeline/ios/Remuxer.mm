///
/// Remuxer.mm — see Remuxer.h for the contract.
///

#import "Remuxer.h"
#import "Remuxer+Internal.h"
#import "ExportSession.h"
#import "SynthesizeRunner.h"
#import "SynthesizeRunner+Internal.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

#include "compose/StopToken.hpp"
#include "engine/Remuxer.hpp"

#include <memory>
#include <optional>
#include <vector>

NSErrorDomain const RNVPRemuxerErrorDomain = @"RNVPRemuxerErrorDomain";

namespace {

NSError *makeError(RNVPRemuxerErrorCode code, NSString *message) {
  return [NSError errorWithDomain:RNVPRemuxerErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

NSString *utf8(const std::string &s) {
  return [[NSString alloc] initWithBytes:s.data()
                                  length:s.size()
                                encoding:NSUTF8StringEncoding]
             ?: @"";
}

AVFileType fileTypeForOutputURL(NSURL *url) {
  NSString *ext = url.pathExtension.lowercaseString;
  if ([ext isEqualToString:@"mov"]) return AVFileTypeQuickTimeMovie;
  // Default to MP4 for anything else — matches RNVPAVMuxer's own output and
  // the "mp4/mov" advertised in VideoContainer.
  return AVFileTypeMPEG4;
}

// Pump every remaining sample from `output` into `input`. Samples are written
// with their original source-time PTS; the writer session was started at the
// source start time so no rebasing is needed (AVAssetWriter emits an edit
// list that makes playback start at 0 in the resulting container).
BOOL pumpPassthroughSamples(AVAssetReaderTrackOutput *output,
                            AVAssetWriterInput *input,
                            AVAssetReader *reader, AVAssetWriter *writer,
                            NSError *_Nullable __autoreleasing *error) {
  // Wait for the writer input to accept more data, then append. No wall-clock
  // deadline (issue #32): the readiness wait ends on a real signal only —
  // the input becoming ready, or the writer entering the Failed state (which
  // pins readiness at NO forever, e.g. an async disk-full failure between
  // appends). `-requestMediaDataWhenReadyOnQueue:` would be the busy-wait-free
  // pull API, but it offers no failure callback: if the writer fails while the
  // input is full, AVFoundation never re-invokes the block and the pump would
  // hang. So we poll readiness and escape on writer.status == Failed, matching
  // the Transcoder pumps. The durable fix is retiring this manual pump in
  // favour of AVAssetExportSession (#19/#14), not an interim API swap.
  while (YES) {
    while (!input.readyForMoreMediaData) {
      if (writer.status == AVAssetWriterStatusFailed) break;
      [NSThread sleepForTimeInterval:0.001];
    }
    if (!input.readyForMoreMediaData) {
      if (error) {
        *error = writer.error
                     ?: makeError(RNVPRemuxerErrorCodeWriterFailed,
                                  @"Writer input never became ready (writer "
                                  @"entered the Failed state).");
      }
      return NO;
    }
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == NULL) {
      AVAssetReaderStatus status = reader.status;
      if (status == AVAssetReaderStatusFailed ||
          status == AVAssetReaderStatusUnknown) {
        if (error) {
          *error = reader.error
                       ?: makeError(RNVPRemuxerErrorCodeSourceCorrupted,
                                    @"AVAssetReader entered the Failed "
                                    @"state.");
        }
        return NO;
      }
      return YES;
    }
    BOOL ok = [input appendSampleBuffer:sample];
    CFRelease(sample);
    if (!ok) {
      if (error) {
        *error = writer.error
                     ?: makeError(RNVPRemuxerErrorCodeWriterFailed,
                                  @"Writer rejected passthrough sample.");
      }
      return NO;
    }
  }
}

} // namespace

namespace {

// Compose the user-requested flip onto the source preferredTransform. The
// flip is authored in the source's natural-pixel frame (pre-rotation) so the
// composition is `Concat(preferred, flip)` — AVFoundation applies transforms
// left-to-right, matching "first the source's rotation, then the flip".
CGAffineTransform flipTransformForAxis(RNVPFlipAxis axis,
                                       CGAffineTransform preferred,
                                       CGSize naturalSize) {
  CGAffineTransform flip;
  if (axis == RNVPFlipAxisHorizontal) {
    flip = CGAffineTransformMake(-1, 0, 0, 1, naturalSize.width, 0);
  } else {
    flip = CGAffineTransformMake(1, 0, 0, -1, 0, naturalSize.height);
  }
  return CGAffineTransformConcat(preferred, flip);
}

// Compose `preferred → rotate → flip` into a single preferredTransform that
// maps the source's natural-pixel frame onto a non-negative displayed frame.
// Each step is applied in display space and the origin re-normalized to 0
// afterward, so rotation/flip translations fall out automatically. Visual
// order matches RNVPTranscoder's CIImage pipeline (rotate clockwise for a
// positive @p rotateDeg, flips applied last) so the remux and transcode paths
// agree on what "rotate 90 + flipH" looks like at playback.
CGAffineTransform composeDisplayTransform(CGAffineTransform preferred,
                                          CGSize naturalSize,
                                          NSInteger rotateDeg, BOOL flipH,
                                          BOOL flipV) {
  const CGRect naturalRect =
      CGRectMake(0, 0, naturalSize.width, naturalSize.height);
  CGAffineTransform t = CGAffineTransformIdentity;
  // Apply @p op after the accumulated transform, then translate so the mapped
  // natural rect's origin returns to (0, 0).
  auto step = [&](CGAffineTransform op) {
    t = CGAffineTransformConcat(t, op);
    const CGRect mapped = CGRectApplyAffineTransform(naturalRect, t);
    t = CGAffineTransformConcat(
        t, CGAffineTransformMakeTranslation(-mapped.origin.x, -mapped.origin.y));
  };
  step(preferred);
  if (rotateDeg == 90 || rotateDeg == 180 || rotateDeg == 270) {
    // CIImage / ClipTransform rotate clockwise for positive degrees; Core
    // Graphics rotates counter-clockwise for positive radians, so negate.
    step(CGAffineTransformMakeRotation(-static_cast<double>(rotateDeg) * M_PI /
                                       180.0));
  }
  if (flipH || flipV) {
    step(CGAffineTransformMakeScale(flipH ? -1.0 : 1.0, flipV ? -1.0 : 1.0));
  }
  return t;
}

} // namespace

@implementation RNVPRemuxerConcatSource

- (instancetype)initWithSourceURL:(NSURL *)sourceURL
                      sourceStart:(double)sourceStart
                   sourceDuration:(double)sourceDuration
                      outputStart:(double)outputStart {
  if ((self = [super init])) {
    _sourceURL = sourceURL;
    _sourceStart = sourceStart;
    _sourceDuration = sourceDuration;
    _outputStart = outputStart;
  }
  return self;
}

@end

@implementation RNVPRemuxer

+ (BOOL)remuxTrimFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                startSec:(double)startSec
             durationSec:(double)durationSec
                   error:(NSError *_Nullable __autoreleasing *)error {
  if (![[NSFileManager defaultManager] fileExistsAtPath:sourceURL.path]) {
    if (error) {
      *error = makeError(
          RNVPRemuxerErrorCodeNotFound,
          [NSString stringWithFormat:@"No file at %@", sourceURL.path]);
    }
    return NO;
  }

  AVURLAsset *asset = [AVURLAsset assetWithURL:sourceURL];
  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (videoTracks.count == 0) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeSourceCorrupted,
                         @"Source has no video track.");
    }
    return NO;
  }

  const double sourceDurationSec = CMTimeGetSeconds(asset.duration);
  margelo::nitro::videopipeline::TrimSpec trim{startSec, durationSec};
  auto rejection = margelo::nitro::videopipeline::describeTrimRejection(
      trim, std::optional<double>(sourceDurationSec));
  if (rejection.has_value()) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeInvalidSpec, utf8(*rejection));
    }
    return NO;
  }

  // Build the source-time window. AVAssetExportSession rebases the output
  // timeline so playback starts at 0 in the resulting container.
  const CMTime startTime = CMTimeMakeWithSeconds(startSec, NSEC_PER_SEC);
  CMTime duration = CMTimeMakeWithSeconds(durationSec, NSEC_PER_SEC);
  const CMTime assetEnd = asset.duration;
  const CMTime requestedEnd = CMTimeAdd(startTime, duration);
  if (CMTimeCompare(requestedEnd, assetEnd) > 0) {
    // End-past-EOF is intentionally allowed by describeTrimRejection (matches
    // AVAssetExportSession / ffmpeg leniency). Clamp here so the export gets
    // a valid in-range window and the output contains whatever samples
    // actually exist between startTime and assetEnd.
    duration = CMTimeSubtract(assetEnd, startTime);
  }
  const CMTimeRange timeRange = CMTimeRangeMake(startTime, duration);

  // Delegate to the unified AVAssetExportSession driver. The hand-rolled
  // AVAssetReader + AVAssetWriter polling pump that lived here previously
  // wedged on real-device slo-mo HEVC (1080p @ 240fps @ ~50Mbps); see commit
  // cb7c972 for the same wedge / same fix on the stamp path.
  //
  // remuxFlip, the transform-remux, and concat now also run through this
  // driver (via initWithComposedAsset:). The metadata-only stamp
  // (remuxStampFromURL) is the last remaining manual-pump user — left as-is
  // for now since it carries its own merged-metadata writer.
  RNVPExportRequest *request =
      [[RNVPExportRequest alloc] initWithSource:sourceURL
                                         output:outputURL
                                      timeRange:timeRange
                                       metadata:asset.metadata
                                       composer:nil
                                           stop:nil
                                       progress:nil];
  NSError *exportError = nil;
  if (![RNVPExportSession runRequest:request error:&exportError]) {
    if (error) {
      NSString *desc = exportError.localizedDescription
                           ?: @"AVAssetExportSession passthrough trim failed.";
      *error = makeError(RNVPRemuxerErrorCodeWriterFailed, desc);
    }
    return NO;
  }
  return YES;
}

+ (BOOL)remuxFlipFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                    axis:(RNVPFlipAxis)axis
                   error:(NSError *_Nullable __autoreleasing *)error {
  if (![[NSFileManager defaultManager] fileExistsAtPath:sourceURL.path]) {
    if (error) {
      *error = makeError(
          RNVPRemuxerErrorCodeNotFound,
          [NSString stringWithFormat:@"No file at %@", sourceURL.path]);
    }
    return NO;
  }

  AVURLAsset *asset = [AVURLAsset assetWithURL:sourceURL];
  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (videoTracks.count == 0) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeSourceCorrupted,
                         @"Source has no video track.");
    }
    return NO;
  }
  AVAssetTrack *videoTrack = videoTracks.firstObject;

  // Container-support gate. MP4/MOV always support preferredTransform at the
  // track level; anything else hits the T033 transcode fallback (not wired).
  AVFileType outputType = fileTypeForOutputURL(outputURL);
  if (![outputType isEqualToString:AVFileTypeMPEG4] &&
      ![outputType isEqualToString:AVFileTypeQuickTimeMovie]) {
    if (error) {
      *error = makeError(
          RNVPRemuxerErrorCodeInvalidSpec,
          @"flip: output container does not support the rotation-flag "
          @"remux path — transcode fallback lands in T033.");
    }
    return NO;
  }

  // Build a single-clip composition with the flipped preferredTransform and run
  // a passthrough export through the unified driver. A composition + the
  // Passthrough preset copies compressed samples verbatim and writes the
  // overridden transform — the same lossless result the retired manual
  // AVAssetReader -> AVAssetWriter pump produced, without the wedge class of
  // bug it hit on real-device slo-mo HEVC (mirrors the trim/transform paths).
  AVMutableComposition *composition = [AVMutableComposition composition];
  AVMutableCompositionTrack *videoCompTrack = [composition
      addMutableTrackWithMediaType:AVMediaTypeVideo
                  preferredTrackID:kCMPersistentTrackID_Invalid];
  const CMTimeRange sourceRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
  NSError *insertError = nil;
  if (videoCompTrack == nil ||
      ![videoCompTrack insertTimeRange:sourceRange
                               ofTrack:videoTrack
                                atTime:kCMTimeZero
                                 error:&insertError]) {
    if (error) {
      *error = insertError
                   ?: makeError(RNVPRemuxerErrorCodeSourceCorrupted,
                                @"flip: could not splice source video into the "
                                @"composition.");
    }
    return NO;
  }
  videoCompTrack.preferredTransform = flipTransformForAxis(
      axis, videoTrack.preferredTransform, videoTrack.naturalSize);

  AVAssetTrack *audioTrack =
      [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
  if (audioTrack != nil) {
    AVMutableCompositionTrack *audioCompTrack = [composition
        addMutableTrackWithMediaType:AVMediaTypeAudio
                    preferredTrackID:kCMPersistentTrackID_Invalid];
    [audioCompTrack insertTimeRange:sourceRange
                            ofTrack:audioTrack
                             atTime:kCMTimeZero
                              error:nil];
  }

  RNVPExportRequest *request =
      [[RNVPExportRequest alloc] initWithComposedAsset:composition
                                                output:outputURL
                                              metadata:asset.metadata
                                                  stop:nil
                                              progress:nil];
  NSError *exportError = nil;
  if (![RNVPExportSession runRequest:request error:&exportError]) {
    if (error) {
      *error = exportError
                   ?: makeError(RNVPRemuxerErrorCodeWriterFailed,
                                @"flip: passthrough export failed.");
    }
    return NO;
  }
  return YES;
}

+ (BOOL)remuxTransformFromURL:(NSURL *)sourceURL
                        toURL:(NSURL *)outputURL
                     startSec:(double)startSec
                  durationSec:(double)durationSec
                       rotate:(NSInteger)rotate
                        flipH:(BOOL)flipH
                        flipV:(BOOL)flipV
                        error:(NSError *_Nullable __autoreleasing *)error {
  if (![[NSFileManager defaultManager] fileExistsAtPath:sourceURL.path]) {
    if (error) {
      *error = makeError(
          RNVPRemuxerErrorCodeNotFound,
          [NSString stringWithFormat:@"No file at %@", sourceURL.path]);
    }
    return NO;
  }

  AVURLAsset *asset = [AVURLAsset assetWithURL:sourceURL];
  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (videoTracks.count == 0) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeSourceCorrupted,
                         @"Source has no video track.");
    }
    return NO;
  }
  AVAssetTrack *videoTrack = videoTracks.firstObject;

  // Container-support gate — same as remuxFlip: preferredTransform is an
  // mp4/mov track feature. Other containers route to the transcode fallback.
  AVFileType outputType = fileTypeForOutputURL(outputURL);
  if (![outputType isEqualToString:AVFileTypeMPEG4] &&
      ![outputType isEqualToString:AVFileTypeQuickTimeMovie]) {
    if (error) {
      *error = makeError(
          RNVPRemuxerErrorCodeInvalidSpec,
          @"transform-remux: output container does not support a "
          @"preferredTransform — re-encode via the transcode path.");
    }
    return NO;
  }

  // Resolve and validate the trim window (shared wording with the plain trim
  // path). A durationSec <= 0 means "to the end of the source".
  const double sourceDurationSec = CMTimeGetSeconds(asset.duration);
  const double windowStart = startSec > 0.0 ? startSec : 0.0;
  margelo::nitro::videopipeline::TrimSpec trim{
      windowStart, durationSec > 0.0 ? durationSec
                                     : (sourceDurationSec - windowStart)};
  if (auto rejection = margelo::nitro::videopipeline::describeTrimRejection(
          trim, std::optional<double>(sourceDurationSec));
      rejection.has_value()) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeInvalidSpec, utf8(*rejection));
    }
    return NO;
  }
  const CMTime startTime = CMTimeMakeWithSeconds(windowStart, NSEC_PER_SEC);
  CMTime windowDuration =
      durationSec > 0.0
          ? CMTimeMakeWithSeconds(durationSec, NSEC_PER_SEC)
          : CMTimeSubtract(asset.duration, startTime);
  if (CMTimeCompare(CMTimeAdd(startTime, windowDuration), asset.duration) > 0) {
    windowDuration = CMTimeSubtract(asset.duration, startTime);  // clamp to EOF
  }
  const CMTimeRange window = CMTimeRangeMake(startTime, windowDuration);

  // Build a single-clip composition so we can override the video track's
  // preferredTransform (a raw passthrough export copies the source transform
  // verbatim and gives us no override hook — same reason the concat path uses
  // a composition).
  AVMutableComposition *composition = [AVMutableComposition composition];
  AVMutableCompositionTrack *videoCompTrack = [composition
      addMutableTrackWithMediaType:AVMediaTypeVideo
                  preferredTrackID:kCMPersistentTrackID_Invalid];
  NSError *insertError = nil;
  if (videoCompTrack == nil ||
      ![videoCompTrack insertTimeRange:window
                               ofTrack:videoTrack
                                atTime:kCMTimeZero
                                 error:&insertError]) {
    if (error) {
      *error = insertError
                   ?: makeError(RNVPRemuxerErrorCodeSourceCorrupted,
                                @"Could not splice source video into the "
                                @"transform composition.");
    }
    return NO;
  }
  videoCompTrack.preferredTransform = composeDisplayTransform(
      videoTrack.preferredTransform, videoTrack.naturalSize, rotate, flipH,
      flipV);

  AVAssetTrack *audioTrack =
      [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
  if (audioTrack != nil) {
    AVMutableCompositionTrack *audioCompTrack = [composition
        addMutableTrackWithMediaType:AVMediaTypeAudio
                    preferredTrackID:kCMPersistentTrackID_Invalid];
    [audioCompTrack insertTimeRange:window
                            ofTrack:audioTrack
                             atTime:kCMTimeZero
                              error:nil];
  }

  // Passthrough export through the unified driver — copies compressed samples,
  // writes the overridden transform. The composition timeline already starts at
  // 0 and bakes the trim window, so no explicit session timeRange is needed.
  RNVPExportRequest *request =
      [[RNVPExportRequest alloc] initWithComposedAsset:composition
                                                output:outputURL
                                              metadata:asset.metadata
                                                  stop:nil
                                              progress:nil];
  NSError *exportError = nil;
  if (![RNVPExportSession runRequest:request error:&exportError]) {
    if (error) {
      *error = exportError
                   ?: makeError(RNVPRemuxerErrorCodeWriterFailed,
                                @"transform-remux: passthrough export failed.");
    }
    return NO;
  }
  return YES;
}

@end

#pragma mark - Concat (T029)

namespace {

// Lightweight, codec-oriented signature used to enforce "all clips share the
// same encoder output" before any export runs. A mismatch here is the
// explicit contract violation that routes future consumers to the transcode
// path; the strings are only used for the error message.
struct VideoTrackSignature {
  FourCharCode codec;
  NSInteger width;
  NSInteger height;
  CGAffineTransform preferredTransform;
};

BOOL transformsAreEqual(CGAffineTransform a, CGAffineTransform b) {
  const CGFloat kEps = 1e-4;
  return std::fabs(a.a - b.a) < kEps && std::fabs(a.b - b.b) < kEps &&
         std::fabs(a.c - b.c) < kEps && std::fabs(a.d - b.d) < kEps &&
         std::fabs(a.tx - b.tx) < kEps && std::fabs(a.ty - b.ty) < kEps;
}

NSString *fourCCString(FourCharCode code) {
  char bytes[5] = {
      static_cast<char>((code >> 24) & 0xFF),
      static_cast<char>((code >> 16) & 0xFF),
      static_cast<char>((code >> 8) & 0xFF),
      static_cast<char>(code & 0xFF),
      '\0',
  };
  return [NSString stringWithUTF8String:bytes] ?: @"";
}

} // namespace

@implementation RNVPRemuxer (Concat)

+ (BOOL)remuxConcatSources:(NSArray<RNVPRemuxerConcatSource *> *)sources
                     toURL:(NSURL *)outputURL
                      stop:(nullable RNVPStopToken *)stopToken
                     error:(NSError *_Nullable __autoreleasing *)error {
  const std::shared_ptr<margelo::nitro::videopipeline::StopToken> stop =
      stopToken != nil
          ? [stopToken cpp]
          : std::shared_ptr<margelo::nitro::videopipeline::StopToken>();

  // Pre-abort shortcut — don't touch the file system at all.
  if (stop && stop->abortRequested()) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeCancelled,
                         @"Concat aborted before it started.");
    }
    return NO;
  }
  // --- JS-mirror pre-flight validation -------------------------------------
  std::vector<margelo::nitro::videopipeline::ConcatClipSpec> clipSpecs;
  clipSpecs.reserve(sources.count);
  for (RNVPRemuxerConcatSource *s in sources) {
    clipSpecs.push_back({
        std::string(s.sourceURL.path.UTF8String ?: ""),
        s.sourceStart,
        s.sourceDuration,
        s.outputStart,
    });
  }
  auto rejection = margelo::nitro::videopipeline::describeConcatRejection(
      clipSpecs);
  if (rejection.has_value()) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeInvalidSpec, utf8(*rejection));
    }
    return NO;
  }

  // --- Resolve + signature-check every source ------------------------------
  NSMutableArray<AVURLAsset *> *assets =
      [NSMutableArray arrayWithCapacity:sources.count];
  NSMutableArray<AVAssetTrack *> *videoTracks =
      [NSMutableArray arrayWithCapacity:sources.count];
  VideoTrackSignature signature = {};
  CMFormatDescriptionRef firstFormat = NULL;
  double totalDurationSec = 0.0;

  for (NSUInteger i = 0; i < sources.count; i++) {
    RNVPRemuxerConcatSource *src = sources[i];
    if (![[NSFileManager defaultManager] fileExistsAtPath:src.sourceURL.path]) {
      if (error) {
        *error = makeError(
            RNVPRemuxerErrorCodeNotFound,
            [NSString
                stringWithFormat:@"concat: clip[%lu] not found at %@",
                                 (unsigned long)i, src.sourceURL.path]);
      }
      return NO;
    }
    AVURLAsset *asset = [AVURLAsset assetWithURL:src.sourceURL];
    NSArray<AVAssetTrack *> *vTracks =
        [asset tracksWithMediaType:AVMediaTypeVideo];
    if (vTracks.count == 0) {
      if (error) {
        *error = makeError(
            RNVPRemuxerErrorCodeSourceCorrupted,
            [NSString stringWithFormat:@"concat: clip[%lu] has no video track",
                                       (unsigned long)i]);
      }
      return NO;
    }
    AVAssetTrack *track = vTracks.firstObject;

    const double assetDurationSec = CMTimeGetSeconds(asset.duration);
    if (src.sourceStart + src.sourceDuration >
        assetDurationSec + 1e-3) {
      if (error) {
        *error = makeError(
            RNVPRemuxerErrorCodeInvalidSpec,
            [NSString stringWithFormat:
                          @"concat: clip[%lu].sourceStart + sourceDuration "
                          @"exceeds source duration (%.3fs)",
                          (unsigned long)i, assetDurationSec]);
      }
      return NO;
    }

    CMFormatDescriptionRef fmt = NULL;
    if (track.formatDescriptions.count > 0) {
      fmt = (__bridge CMFormatDescriptionRef)
          track.formatDescriptions.firstObject;
    }
    const FourCharCode codec =
        fmt != NULL ? CMFormatDescriptionGetMediaSubType(fmt) : 0;
    const CGSize natural = track.naturalSize;
    const CGAffineTransform xform = track.preferredTransform;

    if (i == 0) {
      signature = {
          .codec = codec,
          .width = static_cast<NSInteger>(std::lround(natural.width)),
          .height = static_cast<NSInteger>(std::lround(natural.height)),
          .preferredTransform = xform,
      };
      firstFormat = fmt;
    } else {
      if (codec != signature.codec) {
        if (error) {
          *error = makeError(
              RNVPRemuxerErrorCodeInvalidSpec,
              [NSString
                  stringWithFormat:@"concat: clip[%lu] codec '%@' differs "
                                   @"from clip[0] codec '%@' — transcode "
                                   @"fallback lands in a later task",
                                   (unsigned long)i, fourCCString(codec),
                                   fourCCString(signature.codec)]);
        }
        return NO;
      }
      const NSInteger w =
          static_cast<NSInteger>(std::lround(natural.width));
      const NSInteger h =
          static_cast<NSInteger>(std::lround(natural.height));
      if (w != signature.width || h != signature.height) {
        if (error) {
          *error = makeError(
              RNVPRemuxerErrorCodeInvalidSpec,
              [NSString
                  stringWithFormat:@"concat: clip[%lu] size %ldx%ld differs "
                                   @"from clip[0] size %ldx%ld — transcode "
                                   @"fallback lands in a later task",
                                   (unsigned long)i, (long)w, (long)h,
                                   (long)signature.width,
                                   (long)signature.height]);
        }
        return NO;
      }
      if (!transformsAreEqual(xform, signature.preferredTransform)) {
        if (error) {
          *error = makeError(
              RNVPRemuxerErrorCodeInvalidSpec,
              [NSString
                  stringWithFormat:@"concat: clip[%lu] preferredTransform "
                                   @"differs from clip[0] — normalize "
                                   @"rotation first via Video.flip",
                                   (unsigned long)i]);
        }
        return NO;
      }
    }

    [assets addObject:asset];
    [videoTracks addObject:track];
    totalDurationSec = src.outputStart + src.sourceDuration;
  }

  // --- Build an AVMutableComposition from the clip list -------------------
  // AVAssetExportSession with AVAssetExportPresetPassthrough + AVMutable-
  // Composition is the canonical Apple pattern for cross-clip concat without
  // a re-encode. Manual AVAssetReader→AVAssetWriter sample copying requires
  // rebasing CMSampleBuffer timing, which fails on compressed passthrough
  // buffers (kCMSampleBufferError_BufferHasNoSampleTimingInfo) because the
  // timing info is carried in attachments rather than the struct itself.
  // Letting AVFoundation own the splicing side-steps that entirely.
  AVMutableComposition *composition = [AVMutableComposition composition];
  AVMutableCompositionTrack *compositionVideoTrack =
      [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                               preferredTrackID:kCMPersistentTrackID_Invalid];
  if (compositionVideoTrack == nil) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeWriterFailed,
                         @"AVMutableComposition refused a video track.");
    }
    return NO;
  }
  compositionVideoTrack.preferredTransform = signature.preferredTransform;

  CMTime cursor = kCMTimeZero;
  for (NSUInteger i = 0; i < sources.count; i++) {
    RNVPRemuxerConcatSource *src = sources[i];
    AVAssetTrack *track = videoTracks[i];
    const CMTime clipStart =
        CMTimeMakeWithSeconds(src.sourceStart, NSEC_PER_SEC);
    const CMTime clipDuration =
        CMTimeMakeWithSeconds(src.sourceDuration, NSEC_PER_SEC);
    const CMTimeRange range = CMTimeRangeMake(clipStart, clipDuration);
    NSError *insertError = nil;
    if (![compositionVideoTrack insertTimeRange:range
                                        ofTrack:track
                                         atTime:cursor
                                          error:&insertError]) {
      if (error) {
        *error = insertError
                     ?: makeError(RNVPRemuxerErrorCodeSourceCorrupted,
                                  [NSString stringWithFormat:
                                                @"concat: failed to splice "
                                                @"clip[%lu] into timeline",
                                                (unsigned long)i]);
      }
      return NO;
    }
    cursor = CMTimeAdd(cursor, clipDuration);
  }

  // --- Drive the passthrough export through the unified driver --------------
  // The composition encodes the full concatenated timeline; the driver runs the
  // Passthrough preset, forwards the first source's container metadata, polls
  // the stop token (~50ms) for cancellation, and deletes any partial output on
  // failure. Same driver the trim / flip / transform remuxes use — replaces the
  // hand-rolled AVAssetExportSession block + stop watcher.
  // Later clips' metadata is dropped; a future merge policy can be defined when
  // stamp() learns about multi-clip inputs.
  RNVPExportRequest *request = [[RNVPExportRequest alloc]
      initWithComposedAsset:composition
                     output:outputURL
                   metadata:assets.firstObject.metadata
                       stop:stopToken
                   progress:nil];
  NSError *exportError = nil;
  if (![RNVPExportSession runRequest:request error:&exportError]) {
    if (error) {
      if ([exportError.domain isEqualToString:RNVPExportSessionErrorDomain] &&
          exportError.code == RNVPExportSessionErrorCodeCancelled) {
        *error = makeError(RNVPRemuxerErrorCodeCancelled, @"Concat aborted.");
      } else {
        *error = exportError
                     ?: makeError(RNVPRemuxerErrorCodeWriterFailed,
                                  @"concat: passthrough export failed.");
      }
    }
    return NO;
  }

  // `totalDurationSec` is retained for the unused-variable guard; the
  // composition's own duration is what the export writes.
  (void)totalDurationSec;
  return YES;
}

@end

#pragma mark - Stamp (T032)

@implementation RNVPStampMetadata

- (instancetype)initWithGps:(BOOL)hasGps
                   latitude:(double)latitude
                  longitude:(double)longitude
             hasGpsAltitude:(BOOL)hasGpsAltitude
                   altitude:(double)altitude
                   software:(NSString *)software
               creationDate:(NSDate *)creationDate
         contentDescription:(NSString *)contentDescription
                     custom:(NSDictionary<NSString *, NSString *> *)custom {
  if ((self = [super init])) {
    _hasGps = hasGps;
    _gpsLatitude = latitude;
    _gpsLongitude = longitude;
    _hasGpsAltitude = hasGpsAltitude;
    _gpsAltitude = altitude;
    _software = [software copy];
    _creationDate = [creationDate copy];
    _contentDescription = [contentDescription copy];
    _custom = [custom copy];
  }
  return self;
}

@end

namespace {

// ISO 6709 short form used by AVFoundation for
// @c AVMetadataCommonIdentifierLocation — same shape the demuxer's
// @c parseISO6709 accepts. The altitude token is optional; we emit it
// only when the caller supplied one so a "no altitude" intent is
// distinguishable from "altitude is zero" on the read-back side.
NSString *iso6709FromLatLon(double lat, double lon) {
  return [NSString stringWithFormat:@"%+09.4f%+010.4f/", lat, lon];
}

NSString *iso6709FromLatLonAlt(double lat, double lon, double alt) {
  return [NSString
      stringWithFormat:@"%+09.4f%+010.4f%+09.3f/", lat, lon, alt];
}

AVMutableMetadataItem *makeCommonItem(AVMetadataIdentifier identifier,
                                      id value, NSString *dataType) {
  AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
  item.identifier = identifier;
  item.extendedLanguageTag = @"und";
  item.value = value;
  item.dataType = dataType;
  return item;
}


// Build the full @c writer.metadata array by merging the caller-supplied
// @p metadata onto the source's existing metadata. Source items whose
// identifier matches a field @p metadata explicitly sets are dropped
// (overwrite-by-identifier); every other source item is forwarded. Custom
// keys are appended under the QuickTime metadata keyspace.
NSArray<AVMetadataItem *> *buildMergedMetadata(
    NSArray<AVMetadataItem *> *sourceMetadata,
    RNVPStampMetadata *_Nullable metadata) {
  NSMutableArray<AVMetadataItem *> *out = [NSMutableArray array];
  NSMutableSet<AVMetadataIdentifier> *override =
      [NSMutableSet setWithCapacity:4];
  if (metadata != nil) {
    if (metadata.hasGps) {
      [override addObject:AVMetadataCommonIdentifierLocation];
    }
    if (metadata.software.length > 0) {
      [override addObject:AVMetadataCommonIdentifierSoftware];
    }
    if (metadata.creationDate != nil) {
      [override addObject:AVMetadataCommonIdentifierCreationDate];
    }
    if (metadata.contentDescription.length > 0) {
      [override addObject:AVMetadataCommonIdentifierDescription];
    }
  }
  for (AVMetadataItem *existing in sourceMetadata) {
    if (existing.identifier != nil &&
        [override containsObject:existing.identifier]) {
      continue;
    }
    [out addObject:existing];
  }
  if (metadata == nil) return out;
  if (metadata.hasGps) {
    NSString *iso = metadata.hasGpsAltitude
                        ? iso6709FromLatLonAlt(metadata.gpsLatitude,
                                               metadata.gpsLongitude,
                                               metadata.gpsAltitude)
                        : iso6709FromLatLon(metadata.gpsLatitude,
                                            metadata.gpsLongitude);
    [out addObject:makeCommonItem(
                       AVMetadataCommonIdentifierLocation, iso,
                       (NSString *)kCMMetadataBaseDataType_UTF8)];
  }
  if (metadata.software.length > 0) {
    [out addObject:makeCommonItem(AVMetadataCommonIdentifierSoftware,
                                  metadata.software,
                                  (NSString *)kCMMetadataBaseDataType_UTF8)];
  }
  if (metadata.creationDate != nil) {
    [out addObject:makeCommonItem(AVMetadataCommonIdentifierCreationDate,
                                  metadata.creationDate,
                                  (NSString *)kCMMetadataBaseDataType_RawData)];
  }
  if (metadata.contentDescription.length > 0) {
    [out addObject:makeCommonItem(AVMetadataCommonIdentifierDescription,
                                  metadata.contentDescription,
                                  (NSString *)kCMMetadataBaseDataType_UTF8)];
  }
  for (NSString *key in metadata.custom) {
    NSString *value = metadata.custom[key];
    if (key.length == 0 || value.length == 0) continue;
    // Caller owns the key namespace. We pass the key through verbatim
    // and address it as an `mdta/<key>` AVMetadataItem identifier — the
    // keySpace+key path is silently dropped by AVAssetWriter for MP4
    // output, the explicit `mdta/` identifier persists. Convention is
    // reverse-DNS (e.g. "com.acme.shotanalysis"), but no validation:
    // pass whatever you want, it lands as-is.
    NSString *identifier = [@"mdta/" stringByAppendingString:key];
    AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
    item.identifier = identifier;
    item.value = value;
    item.dataType = (NSString *)kCMMetadataBaseDataType_UTF8;
    item.extendedLanguageTag = @"und";
    [out addObject:item];
  }
  return out;
}

} // namespace

@implementation RNVPRemuxer (Stamp)

+ (BOOL)remuxStampFromURL:(NSURL *)sourceURL
                    toURL:(NSURL *)outputURL
                 metadata:(RNVPStampMetadata *)metadata
                    error:(NSError *_Nullable __autoreleasing *)error {
  if (![[NSFileManager defaultManager] fileExistsAtPath:sourceURL.path]) {
    if (error) {
      *error = makeError(
          RNVPRemuxerErrorCodeNotFound,
          [NSString stringWithFormat:@"No file at %@", sourceURL.path]);
    }
    return NO;
  }

  AVURLAsset *asset = [AVURLAsset assetWithURL:sourceURL];
  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (videoTracks.count == 0) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeSourceCorrupted,
                         @"Source has no video track.");
    }
    return NO;
  }
  AVAssetTrack *videoTrack = videoTracks.firstObject;

  [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

  NSError *writerError = nil;
  AVAssetWriter *writer =
      [[AVAssetWriter alloc] initWithURL:outputURL
                                fileType:fileTypeForOutputURL(outputURL)
                                   error:&writerError];
  if (writer == nil) {
    if (error) {
      *error = writerError
                   ?: makeError(RNVPRemuxerErrorCodeWriterFailed,
                                @"AVAssetWriter init failed.");
    }
    return NO;
  }

  writer.metadata = buildMergedMetadata(asset.metadata, metadata);

  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                         error:&readerError];
  if (reader == nil) {
    if (error) {
      *error = readerError
                   ?: makeError(RNVPRemuxerErrorCodeSourceCorrupted,
                                @"AVAssetReader init failed.");
    }
    return NO;
  }

  // --- Video: reader output + writer input (compressed passthrough) --------
  AVAssetReaderTrackOutput *videoOutput =
      [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack
                                       outputSettings:nil];
  if (![reader canAddOutput:videoOutput]) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeSourceCorrupted,
                         @"AVAssetReader refused passthrough video output.");
    }
    return NO;
  }
  [reader addOutput:videoOutput];

  CMFormatDescriptionRef videoFormat = NULL;
  if (videoTrack.formatDescriptions.count > 0) {
    videoFormat = (__bridge CMFormatDescriptionRef)
        videoTrack.formatDescriptions.firstObject;
  }
  AVAssetWriterInput *videoInput =
      [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                         outputSettings:nil
                                       sourceFormatHint:videoFormat];
  videoInput.expectsMediaDataInRealTime = NO;
  videoInput.transform = videoTrack.preferredTransform;
  if (![writer canAddInput:videoInput]) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeWriterFailed,
                         @"AVAssetWriter refused passthrough video input.");
    }
    return NO;
  }
  [writer addInput:videoInput];

  // --- Optional audio (compressed passthrough) -----------------------------
  AVAssetReaderTrackOutput *audioOutput = nil;
  AVAssetWriterInput *audioInput = nil;
  NSArray<AVAssetTrack *> *audioTracks =
      [asset tracksWithMediaType:AVMediaTypeAudio];
  if (audioTracks.count > 0) {
    AVAssetTrack *audioTrack = audioTracks.firstObject;
    AVAssetReaderTrackOutput *candidateOutput =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack
                                         outputSettings:nil];
    if ([reader canAddOutput:candidateOutput]) {
      [reader addOutput:candidateOutput];
      CMFormatDescriptionRef audioFormat = NULL;
      if (audioTrack.formatDescriptions.count > 0) {
        audioFormat = (__bridge CMFormatDescriptionRef)
            audioTrack.formatDescriptions.firstObject;
      }
      AVAssetWriterInput *candidateInput =
          [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                             outputSettings:nil
                                           sourceFormatHint:audioFormat];
      candidateInput.expectsMediaDataInRealTime = NO;
      if ([writer canAddInput:candidateInput]) {
        [writer addInput:candidateInput];
        audioOutput = candidateOutput;
        audioInput = candidateInput;
      }
    }
  }

  if (![writer startWriting]) {
    if (error) {
      *error = writer.error
                   ?: makeError(RNVPRemuxerErrorCodeWriterFailed,
                                @"AVAssetWriter startWriting failed.");
    }
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    return NO;
  }
  [writer startSessionAtSourceTime:kCMTimeZero];

  if (![reader startReading]) {
    if (error) {
      *error = reader.error
                   ?: makeError(RNVPRemuxerErrorCodeSourceCorrupted,
                                @"AVAssetReader startReading failed.");
    }
    [writer cancelWriting];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    return NO;
  }

  NSError *pumpError = nil;
  BOOL videoOK = pumpPassthroughSamples(videoOutput, videoInput, reader,
                                        writer, &pumpError);
  BOOL audioOK = YES;
  if (videoOK && audioInput != nil) {
    audioOK = pumpPassthroughSamples(audioOutput, audioInput, reader, writer,
                                     &pumpError);
  }

  [videoInput markAsFinished];
  if (audioInput != nil) [audioInput markAsFinished];

  if (!videoOK || !audioOK) {
    [writer cancelWriting];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    if (error) *error = pumpError;
    return NO;
  }

  [writer endSessionAtSourceTime:asset.duration];

  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [writer finishWritingWithCompletionHandler:^{
    dispatch_semaphore_signal(done);
  }];
  // Wait unconditionally — the completion handler always fires (issue #32).
  // The Completed-status check below distinguishes success from failure.
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  if (writer.status != AVAssetWriterStatusCompleted) {
    if (error) {
      *error = writer.error
                   ?: makeError(RNVPRemuxerErrorCodeWriterFailed,
                                @"AVAssetWriter did not reach the Completed "
                                @"status.");
    }
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    return NO;
  }
  return YES;
}

@end

#pragma mark - Stamp metadata merging (shared with the transcode path)

@implementation RNVPStampMetadata (MergeWriting)

- (NSArray<AVMetadataItem *> *)mergedWithSourceMetadata:
    (NSArray<AVMetadataItem *> *)sourceMetadata {
  return buildMergedMetadata(sourceMetadata, self);
}

@end
