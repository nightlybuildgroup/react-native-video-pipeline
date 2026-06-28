///
/// ExportSession.mm — see header for high-level rationale.
///
/// One @c +runRequest:error: entry point that internally branches between
/// the passthrough preset (no composer) and the composition + HighestQuality
/// preset (composer set). The two backend shapes share output-file cleanup,
/// timeRange wiring, metadata wiring, stop-token polling, and status / error
/// reporting — extracted into helpers so the per-branch code stays focused
/// on the AVFoundation-shape-specific work.
///
/// Why @c +applyingCIFiltersWithHandler: in the composition branch instead
/// of a hand-written @c AVVideoCompositing subclass? The hand-written
/// compositor is the canonical pattern but in practice it triggered
/// framework-side fps decimation on the macOS-host XCTest path (a 240fps
/// source emerged as 75fps output). The applying-handler API uses
/// AVFoundation's internal compositor, the same one the rest of AVFoundation
/// uses for CIFilter chains, and it preserves source fps reliably across
/// both macOS-host and iOS-Simulator builds. The custom-compositor approach
/// can come back if we ever need per-frame work the CI handler can't express
/// (multi-track compositing, opaque rendering pipelines).
///
/// The driver runs synchronously via @c dispatch_semaphore so it can be
/// invoked from inside a @c Promise<void>::async lambda without changing
/// call shape.
///

#import "ExportSession.h"

#import "Remuxer+Internal.h"
#import "SynthesizeRunner+Internal.h"
#import "SynthesizeRunner.h"

#import <AVFoundation/AVFoundation.h>

#include <cmath>

NSErrorDomain const RNVPExportSessionErrorDomain =
    @"RNVPExportSessionErrorDomain";

namespace {

NSError *makeError(RNVPExportSessionErrorCode code, NSString *message) {
  return [NSError errorWithDomain:RNVPExportSessionErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

AVFileType fileTypeForOutputURL(NSURL *url) {
  NSString *ext = url.pathExtension.lowercaseString;
  if ([ext isEqualToString:@"mov"]) return AVFileTypeQuickTimeMovie;
  if ([ext isEqualToString:@"m4v"]) return AVFileTypeAppleM4V;
  return AVFileTypeMPEG4;
}

// Absolute-valued (post-preferredTransform) displayed size. Used as
// @c AVMutableVideoComposition.renderSize so the composer's frames are sized
// to what a viewer sees, not the source's pre-rotation natural dimensions.
CGSize displayedSize(AVAssetTrack *videoTrack) {
  const CGSize natural = videoTrack.naturalSize;
  const CGSize applied =
      CGSizeApplyAffineTransform(natural, videoTrack.preferredTransform);
  return CGSizeMake(std::fabs(applied.width), std::fabs(applied.height));
}

}  // namespace

@implementation RNVPExportRequest

- (instancetype)initWithSource:(NSURL *)source
                        output:(NSURL *)output
                     timeRange:(CMTimeRange)timeRange
                      metadata:(NSArray<AVMetadataItem *> *)metadata
                      composer:(RNVPExportSessionComposer)composer
                          stop:(RNVPStopToken *)stop
                      progress:(RNVPExportSessionProgress)progress {
  if ((self = [super init])) {
    _source = source;
    _output = output;
    _timeRange = timeRange;
    _metadata = metadata;
    _composer = composer;
    _stop = stop;
    _progress = progress;
  }
  return self;
}

- (instancetype)initWithComposedAsset:(AVAsset *)composedAsset
                               output:(NSURL *)output
                             metadata:(NSArray<AVMetadataItem *> *)metadata
                                 stop:(RNVPStopToken *)stop
                             progress:(RNVPExportSessionProgress)progress {
  if ((self = [super init])) {
    _composedAsset = composedAsset;
    _output = output;
    // The composition already bakes the window; let the driver default the
    // export session range to the full composition duration.
    _timeRange = kCMTimeRangeInvalid;
    _metadata = metadata;
    _composer = nil; // passthrough — no per-frame re-encode
    _stop = stop;
    _progress = progress;
  }
  return self;
}

@end

@implementation RNVPExportSession

+ (BOOL)runRequest:(RNVPExportRequest *)request
             error:(NSError *__autoreleasing *)error {
  if (request == nil) {
    if (error)
      *error = makeError(RNVPExportSessionErrorCodeInvalidSpec,
                         @"request is nil");
    return NO;
  }
  if (request.source == nil && request.composedAsset == nil) {
    if (error)
      *error = makeError(RNVPExportSessionErrorCodeInvalidSpec,
                         @"neither source nor composedAsset provided");
    return NO;
  }
  if (request.output == nil) {
    if (error)
      *error = makeError(RNVPExportSessionErrorCodeInvalidSpec,
                         @"output is nil");
    return NO;
  }

  // Source asset + video track probe -----------------------------------------
  // A composed asset (AVMutableComposition from flip/transform/concat) is used
  // verbatim; otherwise build a URL asset from the source.
  AVAsset *asset = request.composedAsset
                       ?: [AVURLAsset assetWithURL:request.source];
  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (videoTracks.count == 0) {
    if (error)
      *error = makeError(RNVPExportSessionErrorCodeSourceCorrupted,
                         @"source has no video track");
    return NO;
  }
  AVAssetTrack *sourceVideoTrack = videoTracks.firstObject;

  // Branch the backend shape on whether a per-frame composer is supplied.
  // The composition branch wraps the source in AVMutableComposition and uses
  // the HighestQuality preset so AVFoundation re-encodes through the composer.
  // The passthrough branch hands the raw asset to AVAssetExportSession with
  // the Passthrough preset — compressed samples copy through verbatim.
  AVAsset *exportInput = nil;
  NSString *presetName = nil;
  AVMutableVideoComposition *videoComposition = nil;
  __block NSError *composerError = nil;

  if (request.composer != nil) {
    const CGSize canvas = displayedSize(sourceVideoTrack);
    if (canvas.width <= 0.0 || canvas.height <= 0.0) {
      if (error)
        *error = makeError(RNVPExportSessionErrorCodeSourceCorrupted,
                           @"source video track has degenerate displayed size");
      return NO;
    }

    // The mutable composition gives AVAssetExportSession a clean linear
    // timeline regardless of what container-level edit lists / time mappings
    // the source carries — important for real iPhone slo-mo recordings, which
    // the raw-asset path mis-handles by exporting the time-mapped timeline.
    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableCompositionTrack *videoCompositionTrack = [composition
        addMutableTrackWithMediaType:AVMediaTypeVideo
                    preferredTrackID:kCMPersistentTrackID_Invalid];
    const CMTimeRange sourceRange =
        CMTimeRangeMake(kCMTimeZero, asset.duration);
    NSError *insertError = nil;
    if (![videoCompositionTrack insertTimeRange:sourceRange
                                         ofTrack:sourceVideoTrack
                                          atTime:kCMTimeZero
                                           error:&insertError]) {
      if (error) {
        *error = makeError(
            RNVPExportSessionErrorCodeSourceCorrupted,
            [NSString
                stringWithFormat:@"could not insert source video track: %@",
                                 insertError.localizedDescription ?: @"(nil)"]);
      }
      return NO;
    }
    // Carry the source's preferredTransform forward so AVFoundation orients
    // the source frames the composer receives.
    videoCompositionTrack.preferredTransform =
        sourceVideoTrack.preferredTransform;

    // Audio passthrough — AVAssetExportSession re-emits the audio track from
    // the composition automatically when no audioMix is supplied.
    AVAssetTrack *sourceAudioTrack =
        [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (sourceAudioTrack != nil) {
      AVMutableCompositionTrack *audioCompositionTrack = [composition
          addMutableTrackWithMediaType:AVMediaTypeAudio
                      preferredTrackID:kCMPersistentTrackID_Invalid];
      [audioCompositionTrack insertTimeRange:sourceRange
                                       ofTrack:sourceAudioTrack
                                        atTime:kCMTimeZero
                                         error:nil];
    }

    // Per-frame composer wiring -----------------------------------------------
    // AVFoundation calls the handler once per output frame with the source
    // frame already oriented per the composition track's preferredTransform.
    // The frame counter lives in __block ints so the block can mutate them
    // across invocations.
    __block int32_t frameIndex = 0;
    __block int32_t framesEmitted = 0;
    RNVPExportSessionComposer composer = request.composer;
    RNVPStopToken *stop = request.stop;
    RNVPExportSessionProgress progress = request.progress;

    videoComposition = [AVMutableVideoComposition
        videoCompositionWithAsset:composition
     applyingCIFiltersWithHandler:^(
         AVAsynchronousCIImageFilteringRequest *_Nonnull req) {
          if (stop != nil && stop.abortRequested) {
            [req finishWithError:makeError(
                                     RNVPExportSessionErrorCodeCancelled,
                                     @"export cancelled")];
            return;
          }
          if (composerError != nil) {
            // A previous frame raised; short-circuit the remaining requests
            // so the export session ends quickly with a proper error.
            [req finishWithError:composerError];
            return;
          }
          CIImage *output = nil;
          @try {
            output = composer(req.sourceImage, req.compositionTime, frameIndex);
          } @catch (NSException *exception) {
            composerError = makeError(
                RNVPExportSessionErrorCodeComposerFailed,
                [NSString stringWithFormat:@"composer raised %@: %@",
                                            exception.name, exception.reason]);
            [req finishWithError:composerError];
            return;
          }
          if (output == nil) {
            output = req.sourceImage;
          }
          frameIndex++;
          framesEmitted++;
          if (progress != nil) {
            progress(framesEmitted, 0);
          }
          [req finishWithImage:output context:nil];
        }];

    // Force the composition's output rate to track the source. AVFoundation's
    // applyingCIFiltersWithHandler default reads @c nominalFrameRate, which for
    // real iPhone slo-mo HEVC sources can land on a low value;
    // @c minFrameDuration is the shortest sample interval the source actually
    // uses, a tighter signal.
    const CMTime sourceMinFrameDuration = sourceVideoTrack.minFrameDuration;
    if (CMTIME_IS_VALID(sourceMinFrameDuration) &&
        CMTimeGetSeconds(sourceMinFrameDuration) > 0.0) {
      videoComposition.frameDuration = sourceMinFrameDuration;
    } else if (sourceVideoTrack.nominalFrameRate > 0.0f) {
      videoComposition.frameDuration = CMTimeMake(
          1, (int32_t)std::lround(sourceVideoTrack.nominalFrameRate));
    }

    exportInput = composition;
    presetName = AVAssetExportPresetHighestQuality;
  } else {
    exportInput = asset;
    presetName = AVAssetExportPresetPassthrough;
  }

  // Pre-clean the output path — AVAssetExportSession refuses to overwrite.
  [[NSFileManager defaultManager] removeItemAtURL:request.output error:nil];

  // Run AVAssetExportSession ------------------------------------------------
  AVAssetExportSession *exportSession =
      [[AVAssetExportSession alloc] initWithAsset:exportInput
                                       presetName:presetName];
  if (exportSession == nil) {
    if (error) {
      *error = makeError(
          RNVPExportSessionErrorCodeExportFailed,
          [NSString stringWithFormat:
                        @"could not create AVAssetExportSession with preset %@",
                        presetName]);
    }
    return NO;
  }
  exportSession.outputURL = request.output;
  exportSession.outputFileType = fileTypeForOutputURL(request.output);
  exportSession.shouldOptimizeForNetworkUse = NO;
  if (videoComposition != nil) {
    exportSession.videoComposition = videoComposition;
  }
  // Bound the timeline. Caller-supplied timeRange wins; otherwise default to
  // the asset's reported duration. Without an explicit timeRange,
  // AVAssetExportSession falls back to "every sample the video track contains"
  // — which on some sources is longer than @c asset.duration claims (a 2.66s
  // source produced a 2.99s output / +77 frames in commit cb7c972).
  if (CMTIMERANGE_IS_VALID(request.timeRange) &&
      !CMTIMERANGE_IS_EMPTY(request.timeRange)) {
    exportSession.timeRange = request.timeRange;
  } else {
    exportSession.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
  }
  if (request.metadata != nil) {
    exportSession.metadata = request.metadata;
  }

  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [exportSession exportAsynchronouslyWithCompletionHandler:^{
    dispatch_semaphore_signal(sem);
  }];
  // Poll the stop token alongside the semaphore so a cancellation reaches the
  // export within ~50ms of the request, not whenever the export finishes on
  // its own. 30s is the hard upper bound — wedged session fails the xcodebuild
  // per-test budget rather than the harness budget.
  const uint64_t deadlineNs =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC));
  while (YES) {
    const long signaled = dispatch_semaphore_wait(
        sem, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC));
    if (signaled == 0) break;
    if (dispatch_time(DISPATCH_TIME_NOW, 0) > deadlineNs) {
      [exportSession cancelExport];
      [[NSFileManager defaultManager] removeItemAtURL:request.output
                                                 error:nil];
      if (error) {
        *error = makeError(
            RNVPExportSessionErrorCodeExportFailed,
            @"AVAssetExportSession did not complete within 30s.");
      }
      return NO;
    }
    if (request.stop != nil && request.stop.abortRequested) {
      [exportSession cancelExport];
    }
  }

  if (composerError != nil) {
    [[NSFileManager defaultManager] removeItemAtURL:request.output error:nil];
    if (error) *error = composerError;
    return NO;
  }
  if (exportSession.status != AVAssetExportSessionStatusCompleted) {
    [[NSFileManager defaultManager] removeItemAtURL:request.output error:nil];
    if (error) {
      if (exportSession.status == AVAssetExportSessionStatusCancelled) {
        *error = makeError(RNVPExportSessionErrorCodeCancelled,
                           @"export cancelled");
      } else {
        const NSString *desc =
            exportSession.error.localizedDescription ?: @"(nil)";
        *error = makeError(
            RNVPExportSessionErrorCodeExportFailed,
            [NSString stringWithFormat:
                          @"AVAssetExportSession ended with status %ld: %@",
                          (long)exportSession.status, desc]);
      }
    }
    return NO;
  }
  return YES;
}

@end
