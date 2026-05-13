///
/// ExportSessionStamp.mm — see header for high-level rationale.
///
/// Architecture:
///   - The driver builds a per-frame CI-filter handler that wraps the existing
///     @c RNVPOverlayRenderer (static image + text overlays, anchor math, time
///     ranges). The handler is registered on an @c AVMutableVideoComposition
///     via @c +videoCompositionWithAsset:applyingCIFiltersWithHandler: — an
///     AVFoundation API that resolves the source's @c preferredTransform
///     internally, hands the per-frame source as a pre-oriented @c CIImage,
///     and takes back the composited @c CIImage to feed the encoder.
///   - The export itself runs through @c AVAssetExportSession with the
///     @c HighestQuality preset. AVFoundation owns encoder back-pressure,
///     bitrate selection, GOP placement, and audio passthrough. The hand-
///     rolled @c readyForMoreMediaData polling loop that wedges on real-
///     device slo-mo HEVC is no longer in the picture for this path.
///   - The call is made synchronous via @c dispatch_semaphore so the
///     existing call site (@c HybridVideoPipeline::stamp() inside a
///     @c Promise<void>::async lambda) does not need to change shape.
///

#import "ExportSessionStamp.h"

#import "OverlayRenderer.h"
#import "Remuxer+Internal.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>

NSErrorDomain const RNVPExportSessionStampErrorDomain =
    @"com.unbogify.videopipeline.exportSessionStamp";

namespace {

NSError *makeError(RNVPExportSessionStampErrorCode code, NSString *message) {
  return [NSError errorWithDomain:RNVPExportSessionStampErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

// AVAssetExportSession picks output container by `outputFileType`. Public
// stamp surface always writes mp4 (matches every other writer in the pipeline
// and the @p outPath the Nitro API documents).
AVFileType fileTypeForOutputURL(NSURL *url) {
  NSString *ext = url.pathExtension.lowercaseString;
  if ([ext isEqualToString:@"mov"]) return AVFileTypeQuickTimeMovie;
  if ([ext isEqualToString:@"m4v"]) return AVFileTypeAppleM4V;
  return AVFileTypeMPEG4;
}

// Resolve `naturalSize.applying(preferredTransform)` to an absolute
// width/height pair. The transform may map into negative quadrants
// (mirror/rotate), so a raw |.size| can carry signs the overlay anchor math
// is not prepared for.
CGSize displayedSize(AVAssetTrack *videoTrack) {
  const CGSize natural = videoTrack.naturalSize;
  const CGSize applied =
      CGSizeApplyAffineTransform(natural, videoTrack.preferredTransform);
  return CGSizeMake(std::fabs(applied.width), std::fabs(applied.height));
}

}  // namespace

@implementation RNVPExportSessionStamp

+ (BOOL)stampFromURL:(NSURL *)sourceURL
               toURL:(NSURL *)outputURL
            overlays:(NSArray *)overlays
            metadata:(RNVPStampMetadata *)metadata
               error:(NSError *__autoreleasing *)error {
  if (sourceURL == nil) {
    if (error)
      *error = makeError(RNVPExportSessionStampErrorCodeInvalidSpec,
                         @"sourceURL is nil");
    return NO;
  }
  if (outputURL == nil) {
    if (error)
      *error = makeError(RNVPExportSessionStampErrorCodeInvalidSpec,
                         @"outputURL is nil");
    return NO;
  }

  // Asset + track probe -------------------------------------------------------
  AVURLAsset *asset = [AVURLAsset assetWithURL:sourceURL];
  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (videoTracks.count == 0) {
    if (error)
      *error = makeError(RNVPExportSessionStampErrorCodeSourceCorrupted,
                         @"Source has no video track.");
    return NO;
  }
  AVAssetTrack *videoTrack = videoTracks.firstObject;
  const CGSize canvas = displayedSize(videoTrack);
  if (canvas.width <= 0.0 || canvas.height <= 0.0) {
    if (error)
      *error = makeError(RNVPExportSessionStampErrorCodeSourceCorrupted,
                         @"Source video track has degenerate size.");
    return NO;
  }

  // Overlay renderer ---------------------------------------------------------
  // Pre-rasterizes every image/text overlay into a ready-to-composite CIImage
  // keyed to the displayed canvas. Failures here (bad anchor, missing file,
  // text rasterizer error) get mapped to the export-session driver's error
  // domain so the call site sees one consistent error shape.
  NSError *overlayError = nil;
  RNVPOverlayRenderer *overlayRenderer =
      [[RNVPOverlayRenderer alloc] initWithOverlays:overlays
                                         targetSize:canvas
                                              error:&overlayError];
  if (overlayRenderer == nil) {
    if (error) {
      const NSInteger originalCode = overlayError.code;
      const NSString *originalMessage =
          overlayError.localizedDescription ?: @"(nil)";
      const BOOL isImageLoad =
          originalCode ==
          (NSInteger)RNVPOverlayRendererErrorCodeImageLoadFailed;
      const RNVPExportSessionStampErrorCode mapped =
          isImageLoad ? RNVPExportSessionStampErrorCodeImageLoadFailed
                      : RNVPExportSessionStampErrorCodeInvalidSpec;
      *error = makeError(
          mapped,
          [NSString stringWithFormat:@"overlay prep failed (code %ld): %@",
                                     (long)originalCode, originalMessage]);
    }
    return NO;
  }

  // Per-frame CI handler -----------------------------------------------------
  // AVFoundation calls this block once per output frame with the source frame
  // already oriented per the source's preferredTransform. The handler applies
  // the active overlays (time-range-gated by `compositionTime`) and finishes
  // the request with the composited image. AVFoundation owns everything
  // else — pixel buffer pool, encoder pacing, audio mix passthrough, GOP
  // placement, bitrate selection.
  AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition
      videoCompositionWithAsset:asset
   applyingCIFiltersWithHandler:^(
       AVAsynchronousCIImageFilteringRequest *_Nonnull request) {
        CIImage *source = request.sourceImage;
        const double timeSec = CMTimeGetSeconds(request.compositionTime);
        CIImage *output = [overlayRenderer applyToFrame:source
                                              atTimeSec:timeSec];
        [request finishWithImage:output context:nil];
      }];

  // Force the composition's output frame rate to match the source's actual
  // frame rate. AVFoundation's @c +videoCompositionWithAsset:… reads
  // @c nominalFrameRate to populate @c frameDuration, but for real iPhone
  // slo-mo HEVC recordings the heuristic can land on a low default (the
  // user-visible symptom: a 240fps source exports as ~2fps). We override
  // with @c minFrameDuration, which is the shortest sample interval the
  // source actually uses — always a tighter, more accurate signal than
  // @c nominalFrameRate for variable-rate or slo-mo content.
  const CMTime sourceMinFrameDuration = videoTrack.minFrameDuration;
  if (CMTIME_IS_VALID(sourceMinFrameDuration) &&
      CMTimeGetSeconds(sourceMinFrameDuration) > 0.0) {
    videoComposition.frameDuration = sourceMinFrameDuration;
  } else if (videoTrack.nominalFrameRate > 0.0f) {
    videoComposition.frameDuration =
        CMTimeMake(1, (int32_t)std::lround(videoTrack.nominalFrameRate));
  }

  // Pre-clean the output path so AVAssetExportSession (which refuses to
  // overwrite) does not reject the export at submit time.
  [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

  // Export session ----------------------------------------------------------
  // HighestQuality preset: matches the legacy unbogify Swift module's choice
  // and the de-facto "burn a watermark, keep it visually transparent" preset
  // used across iOS photo/video apps. The encoder picks a target-appropriate
  // bitrate; we deliberately do NOT carry the source's bitrate forward
  // (which is the bug the read/write pump had on slo-mo HEVC sources).
  AVAssetExportSession *exportSession = [[AVAssetExportSession alloc]
      initWithAsset:asset
         presetName:AVAssetExportPresetHighestQuality];
  if (exportSession == nil) {
    if (error)
      *error = makeError(RNVPExportSessionStampErrorCodeExportFailed,
                         @"Could not create AVAssetExportSession with "
                         @"HighestQuality preset for this source.");
    return NO;
  }
  exportSession.outputURL = outputURL;
  exportSession.outputFileType = fileTypeForOutputURL(outputURL);
  exportSession.videoComposition = videoComposition;
  exportSession.shouldOptimizeForNetworkUse = NO;
  // Bound the export to the asset's reported duration. AVAssetExportSession
  // otherwise defaults to "export everything the video track contains,"
  // which on real iPhone slo-mo recordings is longer than @c asset.duration
  // (the source's video track has more raw frames than its time-mapped
  // display window admits — the slo-mo factor is what reconciles them).
  // Result without this line: a 2.66s source produces a 2.99s output.
  exportSession.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
  if (metadata != nil) {
    exportSession.metadata =
        [metadata mergedWithSourceMetadata:asset.metadata];
  }

  // Run synchronously --------------------------------------------------------
  // The caller in HybridVideoPipeline::stamp() is already on Nitro's worker
  // queue (Promise<void>::async), so blocking via dispatch_semaphore_wait is
  // safe and matches the synchronous return shape the existing call site
  // expects. AVAssetExportSession's completion handler runs on its own queue;
  // a single signal/wait pair is sufficient.
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [exportSession exportAsynchronouslyWithCompletionHandler:^{
    dispatch_semaphore_signal(sem);
  }];
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

  if (exportSession.status != AVAssetExportSessionStatusCompleted) {
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    if (error) {
      const NSString *desc =
          exportSession.error.localizedDescription ?: @"(nil)";
      *error = makeError(
          RNVPExportSessionStampErrorCodeExportFailed,
          [NSString
              stringWithFormat:@"AVAssetExportSession ended with status %ld: %@",
                               (long)exportSession.status, desc]);
    }
    return NO;
  }
  return YES;
}

@end
