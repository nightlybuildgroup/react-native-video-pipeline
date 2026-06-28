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

#include <algorithm>
#include <cmath>
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

// Insert the soundtrack dictated by `mode` into the composition-passthrough
// `composition` over `videoRange`. Passthrough copies `sourceAsset`'s own
// audio; Replace pulls the first audio track from `replacementURL`, capped to
// the video duration; Mute inserts nothing. Returns NO only when Replace was
// requested but the replacement is missing / has no audio track — the caller
// fails the remux rather than silently emitting video-only. Passthrough/mute
// always return YES (a source clip with no audio is intentionally silent).
BOOL insertAudioIntoComposition(AVMutableComposition *composition,
                                AVAsset *sourceAsset, CMTimeRange videoRange,
                                RNVPAudioMode mode, NSURL *replacementURL) {
  if (mode == RNVPAudioModeMute) return YES;

  AVAsset *audioAsset = sourceAsset;
  CMTime usable = videoRange.duration;
  if (mode == RNVPAudioModeReplace) {
    if (replacementURL == nil) return NO;
    audioAsset = [AVURLAsset assetWithURL:replacementURL];
    const CMTime replacementDuration = audioAsset.duration;
    if (CMTimeCompare(replacementDuration, usable) < 0) usable = replacementDuration;
  }

  AVAssetTrack *audioTrack =
      [audioAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
  if (audioTrack == nil) return mode != RNVPAudioModeReplace;

  AVMutableCompositionTrack *audioComp = [composition
      addMutableTrackWithMediaType:AVMediaTypeAudio
                  preferredTrackID:kCMPersistentTrackID_Invalid];
  // Passthrough reads from the source window's start; replace from the
  // replacement track's own t=0. Both land at the output's t=0.
  const CMTime readStart =
      mode == RNVPAudioModeReplace ? kCMTimeZero : videoRange.start;
  [audioComp insertTimeRange:CMTimeRangeMake(readStart, usable)
                     ofTrack:audioTrack
                      atTime:kCMTimeZero
                       error:nil];
  return YES;
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
  return [self remuxTrimFromURL:sourceURL
                          toURL:outputURL
                       startSec:startSec
                    durationSec:durationSec
                      audioMode:RNVPAudioModePassthrough
            audioReplacementURL:nil
                          error:error];
}

+ (BOOL)remuxTrimFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                startSec:(double)startSec
             durationSec:(double)durationSec
               audioMode:(RNVPAudioMode)audioMode
     audioReplacementURL:(NSURL *)audioReplacementURL
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
                                      audioMode:audioMode
                            audioReplacementURL:audioReplacementURL
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
  return [self remuxFlipFromURL:sourceURL
                          toURL:outputURL
                           axis:axis
                      audioMode:RNVPAudioModePassthrough
            audioReplacementURL:nil
                          error:error];
}

+ (BOOL)remuxFlipFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                    axis:(RNVPFlipAxis)axis
               audioMode:(RNVPAudioMode)audioMode
     audioReplacementURL:(NSURL *)audioReplacementURL
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

  if (!insertAudioIntoComposition(composition, asset, sourceRange, audioMode,
                                  audioReplacementURL)) {
    if (error) {
      *error = makeError(
          RNVPRemuxerErrorCodeSourceCorrupted,
          @"audio replace: the replacement is missing or has no audio track");
    }
    return NO;
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
  return [self remuxTransformFromURL:sourceURL
                               toURL:outputURL
                            startSec:startSec
                         durationSec:durationSec
                              rotate:rotate
                               flipH:flipH
                               flipV:flipV
                           audioMode:RNVPAudioModePassthrough
                 audioReplacementURL:nil
                               error:error];
}

+ (BOOL)remuxTransformFromURL:(NSURL *)sourceURL
                        toURL:(NSURL *)outputURL
                     startSec:(double)startSec
                  durationSec:(double)durationSec
                       rotate:(NSInteger)rotate
                        flipH:(BOOL)flipH
                        flipV:(BOOL)flipV
                    audioMode:(RNVPAudioMode)audioMode
          audioReplacementURL:(NSURL *)audioReplacementURL
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

  if (!insertAudioIntoComposition(composition, asset, window, audioMode,
                                  audioReplacementURL)) {
    if (error) {
      *error = makeError(
          RNVPRemuxerErrorCodeSourceCorrupted,
          @"audio replace: the replacement is missing or has no audio track");
    }
    return NO;
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
  return [self remuxConcatSources:sources
                            toURL:outputURL
                        audioMode:RNVPAudioModePassthrough
              audioReplacementURL:nil
                             stop:stopToken
                            error:error];
}

+ (BOOL)remuxConcatSources:(NSArray<RNVPRemuxerConcatSource *> *)sources
                     toURL:(NSURL *)outputURL
                 audioMode:(RNVPAudioMode)audioMode
       audioReplacementURL:(NSURL *)audioReplacementURL
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

  // Audio composition track for the passthrough soundtrack. Mute writes video
  // only; passthrough splices each clip's own audio onto the same timeline. A
  // clip without an audio track leaves a silent gap (the composition advances
  // the cursor regardless), so a mixed audio/no-audio concat stays in sync.
  // Created lazily on the first real audio segment so an all-video-only concat
  // emits zero audio tracks. Per-clip splicing applies to passthrough; replace
  // swaps one soundtrack over the whole timeline after the loop; mute writes
  // none.
  const BOOL splicePerClipAudio = audioMode == RNVPAudioModePassthrough;
  AVMutableCompositionTrack *compositionAudioTrack = nil;

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
    // Splice the clip's audio over the same window. Clamp the requested range
    // to the audio track's own available range: audio tracks routinely end a
    // few ms before/after the video, and an over-long insertTimeRange would
    // fail (silently dropping the clip's audio). Best-effort: a clip with no
    // audio just leaves silence for its span, keeping later clips in sync.
    if (splicePerClipAudio) {
      AVAssetTrack *clipAudio =
          [assets[i] tracksWithMediaType:AVMediaTypeAudio].firstObject;
      if (clipAudio != nil) {
        // Intersect the requested window with the audio track's own available
        // range (handles audio that starts after / ends before the video, e.g.
        // edit-list offsets), and re-anchor the segment under the cursor by the
        // same leading offset so it stays aligned to the video.
        const CMTimeRange avail = clipAudio.timeRange;
        const CMTime segStart = CMTimeMaximum(clipStart, avail.start);
        const CMTime segEnd =
            CMTimeMinimum(CMTimeAdd(clipStart, clipDuration),
                          CMTimeRangeGetEnd(avail));
        if (CMTimeCompare(segEnd, segStart) > 0) {
          if (compositionAudioTrack == nil) {
            compositionAudioTrack = [composition
                addMutableTrackWithMediaType:AVMediaTypeAudio
                            preferredTrackID:kCMPersistentTrackID_Invalid];
          }
          const CMTime atTime =
              CMTimeAdd(cursor, CMTimeSubtract(segStart, clipStart));
          [compositionAudioTrack
              insertTimeRange:CMTimeRangeMake(segStart,
                                              CMTimeSubtract(segEnd, segStart))
                      ofTrack:clipAudio
                       atTime:atTime
                        error:nil];
        }
      }
    }
    cursor = CMTimeAdd(cursor, clipDuration);
  }

  // Replace: swap the whole soundtrack for the replacement asset, capped to the
  // joined timeline's duration (`cursor` is now the total). Fail loudly rather
  // than silently emit video-only if the replacement is missing or has no audio.
  if (audioMode == RNVPAudioModeReplace) {
    AVAsset *replAsset = audioReplacementURL != nil
                             ? [AVURLAsset assetWithURL:audioReplacementURL]
                             : nil;
    if ([replAsset tracksWithMediaType:AVMediaTypeAudio].firstObject == nil) {
      if (error) {
        *error = makeError(
            RNVPRemuxerErrorCodeSourceCorrupted,
            audioReplacementURL == nil
                ? @"concat audio replace requires a replacement URL"
                : [NSString stringWithFormat:
                                @"concat audio replace: no audio track in %@",
                                audioReplacementURL.lastPathComponent]);
      }
      return NO;
    }
    insertAudioIntoComposition(composition, /*sourceAsset=*/nil,
                               CMTimeRangeMake(kCMTimeZero, cursor),
                               RNVPAudioModeReplace, audioReplacementURL);
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

+ (BOOL)composeCrossfadeSources:(NSArray<RNVPRemuxerConcatSource *> *)sources
                     renderSize:(CGSize)renderSize
                  frameDuration:(CMTime)frameDuration
                      audioMode:(RNVPAudioMode)audioMode
            audioReplacementURL:(NSURL *)audioReplacementURL
                          toURL:(NSURL *)outputURL
                           stop:(nullable RNVPStopToken *)stopToken
                          error:(NSError *_Nullable __autoreleasing *)error {
  if (stopToken != nil && stopToken.abortRequested) {
    if (error)
      *error = makeError(RNVPRemuxerErrorCodeCancelled,
                         @"Crossfade aborted before it started.");
    return NO;
  }
  if (sources.count < 2) {
    if (error)
      *error = makeError(RNVPRemuxerErrorCodeInvalidSpec,
                         @"crossfade requires at least two sources");
    return NO;
  }

  // Presentation ranges on the output timeline + adjacent-pair overlap checks.
  // Only consecutive clips may overlap; a clip overlapping two neighbours at
  // once, a non-monotonic end, or full containment is rejected (the partition
  // below assumes at most two clips are visible at any instant).
  const double kEps = 1e-3;
  NSMutableArray<AVURLAsset *> *assets =
      [NSMutableArray arrayWithCapacity:sources.count];
  std::vector<double> presStart(sources.count), presEnd(sources.count);
  for (NSUInteger i = 0; i < sources.count; i++) {
    RNVPRemuxerConcatSource *s = sources[i];
    if (![[NSFileManager defaultManager] fileExistsAtPath:s.sourceURL.path]) {
      if (error)
        *error = makeError(RNVPRemuxerErrorCodeNotFound,
                           [NSString stringWithFormat:
                                         @"crossfade: clip[%lu] not found at %@",
                                         (unsigned long)i, s.sourceURL.path]);
      return NO;
    }
    [assets addObject:[AVURLAsset assetWithURL:s.sourceURL]];
    presStart[i] = s.outputStart;
    presEnd[i] = s.outputStart + s.sourceDuration;
    if (i > 0) {
      if (presStart[i] < presStart[i - 1] - kEps ||
          presEnd[i] < presEnd[i - 1] - kEps) {
        if (error)
          *error = makeError(
              RNVPRemuxerErrorCodeInvalidSpec,
              @"crossfade: clips must be sorted with non-decreasing starts and "
              @"ends (a clip fully containing another is not supported)");
        return NO;
      }
    }
    if (i >= 2 && presStart[i] < presEnd[i - 2] - kEps) {
      if (error)
        *error = makeError(
            RNVPRemuxerErrorCodeInvalidSpec,
            @"crossfade: a clip overlapping more than its immediate neighbour "
            @"is not supported");
      return NO;
    }
  }

  // Two ping-pong video tracks so overlapping neighbours land on distinct
  // tracks; same-parity clips never overlap, so multiple clips per track is
  // safe.
  AVMutableComposition *composition = [AVMutableComposition composition];
  AVMutableCompositionTrack *videoTracks[2] = {
      [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                               preferredTrackID:kCMPersistentTrackID_Invalid],
      [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                               preferredTrackID:kCMPersistentTrackID_Invalid]};
  const BOOL splicePerClipAudio = audioMode == RNVPAudioModePassthrough;
  AVMutableCompositionTrack *audioTracks[2] = {nil, nil};
  if (splicePerClipAudio) {
    audioTracks[0] =
        [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                 preferredTrackID:kCMPersistentTrackID_Invalid];
    audioTracks[1] =
        [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                 preferredTrackID:kCMPersistentTrackID_Invalid];
  }

  for (NSUInteger i = 0; i < sources.count; i++) {
    RNVPRemuxerConcatSource *s = sources[i];
    AVURLAsset *asset = assets[i];
    AVAssetTrack *vTrack =
        [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (vTrack == nil) {
      if (error)
        *error = makeError(
            RNVPRemuxerErrorCodeSourceCorrupted,
            [NSString stringWithFormat:@"crossfade: clip[%lu] has no video track",
                                       (unsigned long)i]);
      return NO;
    }
    const CMTime clipStart = CMTimeMakeWithSeconds(s.sourceStart, NSEC_PER_SEC);
    const CMTime clipDuration =
        CMTimeMakeWithSeconds(s.sourceDuration, NSEC_PER_SEC);
    const CMTime at = CMTimeMakeWithSeconds(s.outputStart, NSEC_PER_SEC);
    NSError *insertErr = nil;
    if (![videoTracks[i % 2]
            insertTimeRange:CMTimeRangeMake(clipStart, clipDuration)
                    ofTrack:vTrack
                     atTime:at
                      error:&insertErr]) {
      if (error)
        *error = insertErr ?: makeError(RNVPRemuxerErrorCodeSourceCorrupted,
                                        @"crossfade: video splice failed");
      return NO;
    }
    if (splicePerClipAudio) {
      AVAssetTrack *aTrack =
          [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
      if (aTrack != nil) {
        const CMTimeRange avail = aTrack.timeRange;
        const CMTime segStart = CMTimeMaximum(clipStart, avail.start);
        const CMTime segEnd = CMTimeMinimum(CMTimeAdd(clipStart, clipDuration),
                                            CMTimeRangeGetEnd(avail));
        if (CMTimeCompare(segEnd, segStart) > 0) {
          const CMTime atAudio =
              CMTimeAdd(at, CMTimeSubtract(segStart, clipStart));
          [audioTracks[i % 2]
              insertTimeRange:CMTimeRangeMake(segStart,
                                              CMTimeSubtract(segEnd, segStart))
                      ofTrack:aTrack
                       atTime:atAudio
                        error:nil];
        }
      }
    }
  }

  // Partition the timeline at every clip start/end; within each region at most
  // two clips are visible (guaranteed by the adjacent-pair checks above).
  std::vector<double> bounds;
  for (NSUInteger i = 0; i < sources.count; i++) {
    bounds.push_back(presStart[i]);
    bounds.push_back(presEnd[i]);
  }
  std::sort(bounds.begin(), bounds.end());
  bounds.erase(std::unique(bounds.begin(), bounds.end(),
                           [&](double a, double b) {
                             return std::fabs(a - b) < kEps;
                           }),
               bounds.end());

  NSMutableArray<AVMutableVideoCompositionInstruction *> *instructions =
      [NSMutableArray array];
  AVMutableAudioMix *audioMix = nil;
  // Per-audio-track volume ramp params; built lazily for passthrough.
  AVMutableAudioMixInputParameters *audioParams[2] = {nil, nil};
  if (splicePerClipAudio) {
    for (int t = 0; t < 2; t++) {
      audioParams[t] = [AVMutableAudioMixInputParameters
          audioMixInputParametersWithTrack:audioTracks[t]];
      [audioParams[t] setVolume:1.0f atTime:kCMTimeZero];
    }
  }

  for (size_t b = 0; b + 1 < bounds.size(); b++) {
    const double r0 = bounds[b], r1 = bounds[b + 1];
    if (r1 - r0 < kEps) continue;
    const CMTime t0 = CMTimeMakeWithSeconds(r0, NSEC_PER_SEC);
    const CMTime t1 = CMTimeMakeWithSeconds(r1, NSEC_PER_SEC);
    const CMTimeRange region = CMTimeRangeMake(t0, CMTimeSubtract(t1, t0));
    const double mid = (r0 + r1) / 2.0;
    // Active clips: those whose presentation range covers the region midpoint.
    std::vector<NSUInteger> active;
    for (NSUInteger i = 0; i < sources.count; i++) {
      if (presStart[i] <= mid && mid <= presEnd[i]) active.push_back(i);
    }

    AVMutableVideoCompositionInstruction *inst =
        [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    inst.timeRange = region;
    // backgroundColor defaults to black — a region with no active clip (a gap)
    // renders black, which is the intended fill.

    if (active.empty()) {
      inst.layerInstructions = @[];
    } else if (active.size() == 1) {
      AVMutableVideoCompositionLayerInstruction *li =
          [AVMutableVideoCompositionLayerInstruction
              videoCompositionLayerInstructionWithAssetTrack:
                  videoTracks[active[0] % 2]];
      [li setOpacity:1.0f atTime:t0];
      inst.layerInstructions = @[ li ];
    } else {
      // Overlap region: the earlier clip (smaller index) fades out in front of
      // the later clip, which is fully opaque underneath — a crossfade dissolve.
      const NSUInteger outgoing = active[0];
      const NSUInteger incoming = active[1];
      AVMutableVideoCompositionLayerInstruction *liOut =
          [AVMutableVideoCompositionLayerInstruction
              videoCompositionLayerInstructionWithAssetTrack:
                  videoTracks[outgoing % 2]];
      [liOut setOpacityRampFromStartOpacity:1.0f
                                toEndOpacity:0.0f
                                   timeRange:region];
      AVMutableVideoCompositionLayerInstruction *liIn =
          [AVMutableVideoCompositionLayerInstruction
              videoCompositionLayerInstructionWithAssetTrack:
                  videoTracks[incoming % 2]];
      [liIn setOpacity:1.0f atTime:t0];
      inst.layerInstructions = @[ liOut, liIn ];
      if (splicePerClipAudio) {
        [audioParams[outgoing % 2] setVolumeRampFromStartVolume:1.0f
                                                    toEndVolume:0.0f
                                                      timeRange:region];
        [audioParams[incoming % 2] setVolumeRampFromStartVolume:0.0f
                                                    toEndVolume:1.0f
                                                      timeRange:region];
      }
    }
    [instructions addObject:inst];
  }

  AVMutableVideoComposition *videoComposition =
      [AVMutableVideoComposition videoComposition];
  videoComposition.renderSize = renderSize;
  videoComposition.frameDuration =
      (CMTIME_IS_VALID(frameDuration) && CMTimeGetSeconds(frameDuration) > 0.0)
          ? frameDuration
          : CMTimeMake(1, 30);
  videoComposition.instructions = instructions;

  if (splicePerClipAudio) {
    audioMix = [AVMutableAudioMix audioMix];
    audioMix.inputParameters = @[ audioParams[0], audioParams[1] ];
  } else if (audioMode == RNVPAudioModeReplace) {
    // Replace: one soundtrack over the whole timeline, capped to the picture.
    const CMTime total =
        CMTimeMakeWithSeconds(presEnd[sources.count - 1], NSEC_PER_SEC);
    if (![audioReplacementURL isKindOfClass:[NSURL class]] ||
        [[AVURLAsset assetWithURL:audioReplacementURL]
            tracksWithMediaType:AVMediaTypeAudio]
                .firstObject == nil) {
      if (error)
        *error = makeError(
            RNVPRemuxerErrorCodeSourceCorrupted,
            @"crossfade audio replace: the replacement is missing or has no "
            @"audio track");
      return NO;
    }
    insertAudioIntoComposition(composition, /*sourceAsset=*/nil,
                               CMTimeRangeMake(kCMTimeZero, total),
                               RNVPAudioModeReplace, audioReplacementURL);
  }

  RNVPExportRequest *request = [[RNVPExportRequest alloc]
      initWithComposedAsset:composition
           videoComposition:videoComposition
                   audioMix:audioMix
                     output:outputURL
                   metadata:assets.firstObject.metadata
                       stop:stopToken
                   progress:nil];
  NSError *exportError = nil;
  if (![RNVPExportSession runRequest:request error:&exportError]) {
    if (error) {
      if ([exportError.domain isEqualToString:RNVPExportSessionErrorDomain] &&
          exportError.code == RNVPExportSessionErrorCodeCancelled) {
        *error = makeError(RNVPRemuxerErrorCodeCancelled, @"Crossfade aborted.");
      } else {
        *error = exportError ?: makeError(RNVPRemuxerErrorCodeWriterFailed,
                                          @"crossfade: export failed.");
      }
    }
    return NO;
  }
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
  return [self remuxStampFromURL:sourceURL
                           toURL:outputURL
                        metadata:metadata
                       audioMode:RNVPAudioModePassthrough
             audioReplacementURL:nil
                           error:error];
}

+ (BOOL)remuxStampFromURL:(NSURL *)sourceURL
                    toURL:(NSURL *)outputURL
                 metadata:(RNVPStampMetadata *)metadata
                audioMode:(RNVPAudioMode)audioMode
      audioReplacementURL:(NSURL *)audioReplacementURL
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
  // Passthrough copies the source audio; Mute drops it (skip the input
  // entirely). Replace on this metadata-stamp pump needs a second reader on the
  // replacement file — not wired here yet (#29 follow-up); it is unreachable
  // while the JS layer rejects 'replace', so it conservatively drops audio.
  AVAssetReaderTrackOutput *audioOutput = nil;
  AVAssetWriterInput *audioInput = nil;
  NSArray<AVAssetTrack *> *audioTracks =
      [asset tracksWithMediaType:AVMediaTypeAudio];
  if (audioMode == RNVPAudioModePassthrough && audioTracks.count > 0) {
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
