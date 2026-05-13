///
/// ExportSession.mm — see header for high-level rationale.
///
/// Implementation:
///
///   AVURLAsset
///     → AVMutableComposition (insertTimeRange: ofTrack:)
///     → AVMutableVideoComposition built via
///       +videoCompositionWithAsset:applyingCIFiltersWithHandler:
///     → AVAssetExportSession (HighestQuality preset)
///
/// The composition is built against the @c AVMutableComposition (not the
/// raw asset) so the export-session sees a clean linear timeline, regardless
/// of whatever container-side packaging the source recording carries (edit
/// lists, time mappings, etc). The CI handler is the per-frame seam: it
/// receives the source frame as a pre-oriented @c CIImage and is expected to
/// return the composited @c CIImage to feed the encoder.
///
/// Why @c +applyingCIFiltersWithHandler: instead of a hand-written
/// @c AVVideoCompositing subclass? The hand-written compositor is the
/// canonical pattern but in practice it triggered framework-side fps
/// decimation on the macOS-host XCTest path (a 240fps source emerged as
/// 75fps output). The applying-handler API uses AVFoundation's internal
/// compositor, which is the same one the rest of AVFoundation uses for
/// CIFilter chains, and it preserves source fps reliably across both
/// macOS-host and iOS-Simulator builds. The custom-compositor approach can
/// come back if we ever need per-frame work the CI handler can't express
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

@implementation RNVPExportSession

+ (BOOL)exportFromURL:(NSURL *)sourceURL
                toURL:(NSURL *)outputURL
              composer:(RNVPExportSessionComposer)composer
              metadata:(RNVPStampMetadata *)metadata
                  stop:(RNVPStopToken *)stop
              progress:(RNVPExportSessionProgress)progress
                 error:(NSError *__autoreleasing *)error {
  if (sourceURL == nil) {
    if (error)
      *error = makeError(RNVPExportSessionErrorCodeInvalidSpec,
                         @"sourceURL is nil");
    return NO;
  }
  if (outputURL == nil) {
    if (error)
      *error = makeError(RNVPExportSessionErrorCodeInvalidSpec,
                         @"outputURL is nil");
    return NO;
  }
  if (composer == nil) {
    if (error)
      *error = makeError(RNVPExportSessionErrorCodeInvalidSpec,
                         @"composer is nil");
    return NO;
  }

  // Source asset + video track probe -----------------------------------------
  AVURLAsset *asset = [AVURLAsset assetWithURL:sourceURL];
  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (videoTracks.count == 0) {
    if (error)
      *error = makeError(RNVPExportSessionErrorCodeSourceCorrupted,
                         @"source has no video track");
    return NO;
  }
  AVAssetTrack *sourceVideoTrack = videoTracks.firstObject;
  const CGSize canvas = displayedSize(sourceVideoTrack);
  if (canvas.width <= 0.0 || canvas.height <= 0.0) {
    if (error)
      *error = makeError(RNVPExportSessionErrorCodeSourceCorrupted,
                         @"source video track has degenerate displayed size");
    return NO;
  }

  // Wrap source tracks in AVMutableComposition. -----------------------------
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
  videoCompositionTrack.preferredTransform = sourceVideoTrack.preferredTransform;

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

  // Per-frame composer wiring ------------------------------------------------
  // AVFoundation calls the handler once per output frame with the source
  // frame already oriented per the composition track's preferredTransform.
  // The frame counter lives in a captured mutable box because the block is
  // re-entered per frame; ints/floats can't be captured by-reference in
  // Obj-C blocks without @c __block, and a heap-allocated holder is the
  // simplest way to keep it across invocations.
  __block int32_t frameIndex = 0;
  __block int32_t framesEmitted = 0;
  __block NSError *composerError = nil;

  AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition
      videoCompositionWithAsset:composition
   applyingCIFiltersWithHandler:^(
       AVAsynchronousCIImageFilteringRequest *_Nonnull request) {
        if (stop != nil && stop.abortRequested) {
          [request finishWithError:makeError(
                                       RNVPExportSessionErrorCodeCancelled,
                                       @"export cancelled")];
          return;
        }
        if (composerError != nil) {
          // A previous frame raised; short-circuit the remaining requests
          // so the export session ends quickly with a proper error.
          [request finishWithError:composerError];
          return;
        }
        CIImage *output = nil;
        @try {
          output = composer(request.sourceImage, request.compositionTime,
                            frameIndex);
        } @catch (NSException *exception) {
          composerError = makeError(
              RNVPExportSessionErrorCodeComposerFailed,
              [NSString stringWithFormat:@"composer raised %@: %@",
                                          exception.name, exception.reason]);
          [request finishWithError:composerError];
          return;
        }
        if (output == nil) {
          output = request.sourceImage;
        }
        frameIndex++;
        framesEmitted++;
        if (progress != nil) {
          // totalFrameCount isn't known precisely without probing the
          // source's sample count — use the asset duration divided by the
          // frame duration as an approximation. The actual total may differ
          // by ±1 for fractional-fps sources.
          progress(framesEmitted, 0);
        }
        [request finishWithImage:output context:nil];
      }];

  // Force the composition's output rate to track the source. AVFoundation's
  // applyingCIFiltersWithHandler default reads @c nominalFrameRate, which for
  // real iPhone slo-mo HEVC sources can land on a low value; @c minFrameDuration
  // is the shortest sample interval the source actually uses, a tighter signal.
  const CMTime sourceMinFrameDuration = sourceVideoTrack.minFrameDuration;
  if (CMTIME_IS_VALID(sourceMinFrameDuration) &&
      CMTimeGetSeconds(sourceMinFrameDuration) > 0.0) {
    videoComposition.frameDuration = sourceMinFrameDuration;
  } else if (sourceVideoTrack.nominalFrameRate > 0.0f) {
    videoComposition.frameDuration =
        CMTimeMake(1, (int32_t)std::lround(sourceVideoTrack.nominalFrameRate));
  }

  // Pre-clean the output path -------------------------------------------------
  [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

  // Run AVAssetExportSession --------------------------------------------------
  AVAssetExportSession *exportSession = [[AVAssetExportSession alloc]
      initWithAsset:composition
         presetName:AVAssetExportPresetHighestQuality];
  if (exportSession == nil) {
    if (error)
      *error = makeError(RNVPExportSessionErrorCodeExportFailed,
                         @"could not create AVAssetExportSession with the "
                         @"HighestQuality preset");
    return NO;
  }
  exportSession.outputURL = outputURL;
  exportSession.outputFileType = fileTypeForOutputURL(outputURL);
  exportSession.videoComposition = videoComposition;
  exportSession.shouldOptimizeForNetworkUse = NO;
  // Bound the timeline to the asset's reported duration. Without this,
  // AVAssetExportSession defaults to "every sample the video track contains"
  // — which on some sources is longer than @c asset.duration claims.
  exportSession.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
  if (metadata != nil) {
    exportSession.metadata =
        [metadata mergedWithSourceMetadata:asset.metadata];
  }

  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [exportSession exportAsynchronouslyWithCompletionHandler:^{
    dispatch_semaphore_signal(sem);
  }];
  // Poll the stop token alongside the semaphore so a cancellation reaches
  // the export within ~50ms of the request, not whenever the export
  // finishes on its own.
  while (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                                     50 * NSEC_PER_MSEC)) !=
         0) {
    if (stop != nil && stop.abortRequested) {
      [exportSession cancelExport];
    }
  }

  if (composerError != nil) {
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    if (error) *error = composerError;
    return NO;
  }
  if (exportSession.status != AVAssetExportSessionStatusCompleted) {
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
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
