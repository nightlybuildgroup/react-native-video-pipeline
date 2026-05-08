///
/// Thumbnailer.mm — see Thumbnailer.h for the contract.
///

#import "Thumbnailer.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>

NSErrorDomain const RNVPThumbnailerErrorDomain = @"RNVPThumbnailerErrorDomain";

namespace {

NSError *makeError(RNVPThumbnailerErrorCode code, NSString *message) {
  return [NSError errorWithDomain:RNVPThumbnailerErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

// Longest-side semantics. The source `srcW`/`srcH` is scaled to fit inside the
// bounding box formed by the non-zero dimensions of `targetW`/`targetH`,
// preserving aspect ratio. Returns integer pixel dimensions. Zero / negative
// values mean "unconstrained along that axis".
CGSize computeTargetSize(CGFloat srcW, CGFloat srcH, CGFloat targetW,
                         CGFloat targetH) {
  if (srcW <= 0 || srcH <= 0) return CGSizeMake(srcW, srcH);
  const BOOL hasW = targetW > 0;
  const BOOL hasH = targetH > 0;
  if (!hasW && !hasH) return CGSizeMake(srcW, srcH);

  CGFloat scale = 1.0;
  if (hasW && hasH) {
    // Fit inside the bounding box — the dimension whose source side is longer
    // relative to its target side wins, so the other side shrinks further.
    scale = MIN(targetW / srcW, targetH / srcH);
  } else if (hasW) {
    scale = targetW / srcW;
  } else {
    scale = targetH / srcH;
  }

  CGFloat w = MAX(1.0, floor(srcW * scale));
  CGFloat h = MAX(1.0, floor(srcH * scale));
  return CGSizeMake(w, h);
}

BOOL writeCGImageAsJPEG(CGImageRef image, NSURL *outputURL,
                        NSError *_Nullable __autoreleasing *error) {
  // "public.jpeg" is the portable UTI string for JPEG across iOS and macOS.
  CFStringRef jpegUTI = CFSTR("public.jpeg");
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)outputURL, jpegUTI, 1, NULL);
  if (dest == NULL) {
    if (error) {
      *error = makeError(RNVPThumbnailerErrorCodeWriteFailed,
                         @"Could not create CGImageDestination for output URL.");
    }
    return NO;
  }
  // Quality 0.9 — visually indistinguishable from source, ~⅓ the bytes of 1.0.
  NSDictionary *props = @{(id)kCGImageDestinationLossyCompressionQuality : @0.9};
  CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)props);
  const BOOL ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  if (!ok) {
    if (error) {
      *error = makeError(RNVPThumbnailerErrorCodeWriteFailed,
                         @"CGImageDestinationFinalize returned false.");
    }
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    return NO;
  }
  return YES;
}

} // namespace

@implementation RNVPThumbnailer

+ (BOOL)generateThumbnailFromURL:(NSURL *)sourceURL
                           toURL:(NSURL *)outputURL
                           atSec:(double)atSec
                     resizeWidth:(double)resizeWidth
                    resizeHeight:(double)resizeHeight
                           error:(NSError *_Nullable __autoreleasing *)error {
  if (sourceURL == nil || outputURL == nil) {
    if (error) {
      *error = makeError(RNVPThumbnailerErrorCodeInvalidSpec,
                         @"sourceURL and outputURL must be non-nil.");
    }
    return NO;
  }
  if (!(atSec >= 0.0)) {
    if (error) {
      *error = makeError(RNVPThumbnailerErrorCodeInvalidSpec,
                         @"atSec must be >= 0.");
    }
    return NO;
  }
  if (sourceURL.isFileURL &&
      ![[NSFileManager defaultManager] fileExistsAtPath:sourceURL.path]) {
    if (error) {
      *error = makeError(RNVPThumbnailerErrorCodeNotFound,
                         [NSString stringWithFormat:
                                       @"Source file does not exist: %@",
                                       sourceURL.path]);
    }
    return NO;
  }

  AVURLAsset *asset =
      [AVURLAsset URLAssetWithURL:sourceURL
                          options:@{AVURLAssetPreferPreciseDurationAndTimingKey
                                    : @YES}];
  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (videoTracks.count == 0) {
    if (error) {
      *error = makeError(RNVPThumbnailerErrorCodeGenerationFailed,
                         @"Source has no video track.");
    }
    return NO;
  }
  AVAssetTrack *videoTrack = videoTracks.firstObject;
  const CGSize naturalSize = videoTrack.naturalSize;
  const CGSize targetSize = computeTargetSize(
      naturalSize.width, naturalSize.height,
      (CGFloat)resizeWidth, (CGFloat)resizeHeight);

  AVAssetImageGenerator *gen =
      [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
  gen.appliesPreferredTrackTransform = YES;
  // Nail down the time tolerance so tests can trust that the returned frame
  // corresponds exactly to `atSec`. AVFoundation's default is +∞/+∞ which can
  // silently hand back a keyframe seconds away from the requested time.
  gen.requestedTimeToleranceBefore = kCMTimeZero;
  gen.requestedTimeToleranceAfter = kCMTimeZero;
  gen.maximumSize = targetSize;

  // Clamp the requested time into [0, duration]. AVFoundation itself is
  // lenient (returns the nearest on-disk frame for out-of-range times), but
  // making the clamp explicit here keeps the behavior documentable.
  CMTime duration = asset.duration;
  Float64 durationSec = CMTimeGetSeconds(duration);
  double clamped = atSec;
  if (durationSec > 0 && clamped > durationSec) clamped = durationSec;
  CMTime time = CMTimeMakeWithSeconds(clamped, 600);

  CMTime actualTime = kCMTimeZero;
  NSError *genError = nil;
  CGImageRef image = [gen copyCGImageAtTime:time
                                 actualTime:&actualTime
                                      error:&genError];
  if (image == NULL) {
    if (error) {
      NSString *desc = genError.localizedDescription
                           ?: @"AVAssetImageGenerator returned no image.";
      *error = makeError(RNVPThumbnailerErrorCodeGenerationFailed, desc);
    }
    return NO;
  }

  // Make sure the output directory exists — callers expect a single JPEG
  // write, not a "you forgot to mkdir -p" surprise.
  NSURL *parent = outputURL.URLByDeletingLastPathComponent;
  if (parent != nil) {
    [[NSFileManager defaultManager] createDirectoryAtURL:parent
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
  }
  [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

  const BOOL wrote = writeCGImageAsJPEG(image, outputURL, error);
  CGImageRelease(image);
  return wrote;
}

@end
