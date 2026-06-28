///
/// ExportSessionStamp.mm — see header for high-level rationale.
///
/// Thin convenience facade over @c RNVPExportSession: builds an
/// @c RNVPOverlayRenderer from the supplied overlays + canvas size, wraps
/// it in a composer block, and delegates to the generic driver. All the
/// AVAssetExportSession / AVMutableComposition / AVVideoCompositing work
/// lives in @c RNVPExportSession; this class exists so the stamp call site
/// (and the existing XCTests) have a one-line entry point that doesn't have
/// to know about Core Image render context plumbing.
///

#import "ExportSessionStamp.h"

#import "ExportSession.h"
#import "OverlayRenderer.h"
#import "Remuxer+Internal.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>

NSErrorDomain const RNVPExportSessionStampErrorDomain =
    @"RNVPExportSessionStampErrorDomain";

namespace {

NSError *makeError(RNVPExportSessionStampErrorCode code, NSString *message) {
  return [NSError errorWithDomain:RNVPExportSessionStampErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

// Translate the driver's error codes into the stamp-specific domain so the
// call site sees one consistent error shape regardless of which layer the
// failure originated in.
NSError *mapDriverError(NSError *driverError) {
  if (driverError == nil) {
    return makeError(RNVPExportSessionStampErrorCodeExportFailed,
                     @"unspecified driver failure");
  }
  RNVPExportSessionStampErrorCode mapped =
      RNVPExportSessionStampErrorCodeExportFailed;
  if ([driverError.domain isEqualToString:RNVPExportSessionErrorDomain]) {
    switch ((RNVPExportSessionErrorCode)driverError.code) {
      case RNVPExportSessionErrorCodeInvalidSpec:
        mapped = RNVPExportSessionStampErrorCodeInvalidSpec;
        break;
      case RNVPExportSessionErrorCodeSourceCorrupted:
        mapped = RNVPExportSessionStampErrorCodeSourceCorrupted;
        break;
      case RNVPExportSessionErrorCodeExportFailed:
      case RNVPExportSessionErrorCodeCancelled:
      case RNVPExportSessionErrorCodeComposerFailed:
        mapped = RNVPExportSessionStampErrorCodeExportFailed;
        break;
    }
  }
  return makeError(mapped, driverError.localizedDescription ?: @"(nil)");
}

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
            progress:(RNVPExportSessionProgress)progress
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

  // Probe the source so the overlay renderer can resolve anchor math against
  // the displayed canvas — same size the driver will set as
  // AVVideoComposition.renderSize.
  AVURLAsset *asset = [AVURLAsset assetWithURL:sourceURL];
  AVAssetTrack *videoTrack =
      [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  if (videoTrack == nil) {
    if (error)
      *error = makeError(RNVPExportSessionStampErrorCodeSourceCorrupted,
                         @"source has no video track");
    return NO;
  }
  const CGSize canvas = displayedSize(videoTrack);

  NSError *overlayError = nil;
  RNVPOverlayRenderer *overlayRenderer =
      [[RNVPOverlayRenderer alloc] initWithOverlays:overlays
                                         targetSize:canvas
                                              error:&overlayError];
  if (overlayRenderer == nil) {
    if (error) {
      const BOOL isImageLoad =
          overlayError.code ==
          (NSInteger)RNVPOverlayRendererErrorCodeImageLoadFailed;
      const RNVPExportSessionStampErrorCode mapped =
          isImageLoad ? RNVPExportSessionStampErrorCodeImageLoadFailed
                      : RNVPExportSessionStampErrorCodeInvalidSpec;
      *error = makeError(
          mapped,
          [NSString stringWithFormat:@"overlay prep failed: %@",
                                     overlayError.localizedDescription ?: @"(nil)"]);
    }
    return NO;
  }

  RNVPExportSessionComposer composer =
      ^CIImage *(CIImage *source, CMTime t, int32_t i) {
        return [overlayRenderer applyToFrame:source
                                   atTimeSec:CMTimeGetSeconds(t)];
      };

  // Merge stamp metadata over the source's container metadata before handing
  // it to the driver — the driver itself is format-agnostic.
  NSArray<AVMetadataItem *> *mergedMetadata =
      metadata != nil ? [metadata mergedWithSourceMetadata:asset.metadata]
                      : nil;

  RNVPExportRequest *request =
      [[RNVPExportRequest alloc] initWithSource:sourceURL
                                         output:outputURL
                                      timeRange:kCMTimeRangeInvalid
                                       metadata:mergedMetadata
                                       composer:composer
                                      audioMode:RNVPAudioModePassthrough
                            audioReplacementURL:nil
                                           stop:nil
                                       progress:progress];

  NSError *driverError = nil;
  const BOOL ok = [RNVPExportSession runRequest:request error:&driverError];
  if (!ok && error) {
    *error = mapDriverError(driverError);
  }
  return ok;
}

@end
