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

namespace {

// Stable key for a CMTime so the async completion handler can map an emitted
// frame back to the requested time. We build every requested time at timescale
// 600, and AVFoundation hands the same boxed value back as `requestedTime`, so
// "value/timescale" round-trips exactly. Keying this way (rather than by
// seconds) avoids any float-compare fuzz.
NSString *keyForCMTime(CMTime t) {
  return [NSString stringWithFormat:@"%lld/%d", (long long)t.value, t.timescale];
}

// Write `image` to `outputURL`, creating the parent directory and clobbering
// any existing file first — the same single-frame contract, factored out for
// the batch loop.
BOOL writeFrameToURL(CGImageRef image, NSURL *outputURL) {
  NSURL *parent = outputURL.URLByDeletingLastPathComponent;
  if (parent != nil) {
    [[NSFileManager defaultManager] createDirectoryAtURL:parent
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
  }
  [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
  return writeCGImageAsJPEG(image, outputURL, nil);
}

} // namespace

@implementation RNVPThumbnailer (Batch)

+ (nullable NSArray<NSString *> *)
    generateThumbnailsFromURL:(NSURL *)sourceURL
                   toURLs:(NSArray<NSURL *> *)outputURLs
                   atSecs:(NSArray<NSNumber *> *)atSecs
             toleranceSec:(double)toleranceSec
              resizeWidth:(double)resizeWidth
             resizeHeight:(double)resizeHeight
                    error:(NSError *_Nullable __autoreleasing *)error {
  if (sourceURL == nil || atSecs.count == 0 ||
      outputURLs.count != atSecs.count) {
    if (error) {
      *error = makeError(RNVPThumbnailerErrorCodeInvalidSpec,
                         @"atSecs and outputURLs must be non-empty parallel "
                         @"arrays of equal length.");
    }
    return nil;
  }
  if (!(toleranceSec >= 0.0)) {
    if (error) {
      *error = makeError(RNVPThumbnailerErrorCodeInvalidSpec,
                         @"toleranceSec must be >= 0.");
    }
    return nil;
  }
  if (sourceURL.isFileURL &&
      ![[NSFileManager defaultManager] fileExistsAtPath:sourceURL.path]) {
    if (error) {
      *error = makeError(RNVPThumbnailerErrorCodeNotFound,
                         [NSString stringWithFormat:
                                       @"Source file does not exist: %@",
                                       sourceURL.path]);
    }
    return nil;
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
    return nil;
  }
  AVAssetTrack *videoTrack = videoTracks.firstObject;
  const CGSize naturalSize = videoTrack.naturalSize;
  const CGSize targetSize = computeTargetSize(
      naturalSize.width, naturalSize.height,
      (CGFloat)resizeWidth, (CGFloat)resizeHeight);

  // ONE generator drives the whole batch — single asset open, single forward
  // decode walk, single teardown. `generateCGImagesAsynchronouslyForTimes:`
  // sorts internally and reuses the decode session across the requested times.
  AVAssetImageGenerator *gen =
      [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
  gen.appliesPreferredTrackTransform = YES;
  const CMTime tol = CMTimeMakeWithSeconds(toleranceSec, 600);
  gen.requestedTimeToleranceBefore = tol;
  gen.requestedTimeToleranceAfter = tol;
  gen.maximumSize = targetSize;

  const Float64 durationSec = CMTimeGetSeconds(asset.duration);

  // Per output slot: the clamped CMTime we want. Dedup to a unique time set for
  // the generator (duplicate times decode once, then fan back out to slots).
  NSMutableArray<NSValue *> *slotTimes =
      [NSMutableArray arrayWithCapacity:atSecs.count];
  NSMutableArray<NSValue *> *uniqueTimes = [NSMutableArray array];
  NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];
  for (NSNumber *n in atSecs) {
    double clamped = n.doubleValue;
    if (clamped < 0.0) clamped = 0.0;
    if (durationSec > 0 && clamped > durationSec) clamped = durationSec;
    CMTime t = CMTimeMakeWithSeconds(clamped, 600);
    [slotTimes addObject:[NSValue valueWithCMTime:t]];
    NSString *key = keyForCMTime(t);
    if (![seenKeys containsObject:key]) {
      [seenKeys addObject:key];
      [uniqueTimes addObject:[NSValue valueWithCMTime:t]];
    }
  }

  NSMutableDictionary<NSString *, id> *imagesByKey =
      [NSMutableDictionary dictionary];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSInteger remaining = (NSInteger)uniqueTimes.count;
  NSObject *lock = [NSObject new];

  [gen generateCGImagesAsynchronouslyForTimes:uniqueTimes
                            completionHandler:^(CMTime requestedTime,
                                                CGImageRef _Nullable image,
                                                CMTime actualTime,
                                                AVAssetImageGeneratorResult result,
                                                NSError *_Nullable genError) {
    @synchronized(lock) {
      if (result == AVAssetImageGeneratorSucceeded && image != NULL) {
        CGImageRetain(image);
        imagesByKey[keyForCMTime(requestedTime)] = (__bridge id)image;
      }
      // AVAssetImageGeneratorFailed / Cancelled → leave the slot empty; the
      // batch resolves the rest (partial-success contract).
      remaining -= 1;
      if (remaining <= 0) dispatch_semaphore_signal(sem);
    }
  }];
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

  NSMutableArray<NSString *> *results =
      [NSMutableArray arrayWithCapacity:atSecs.count];
  for (NSUInteger i = 0; i < slotTimes.count; i++) {
    CMTime t = slotTimes[i].CMTimeValue;
    id imgVal = imagesByKey[keyForCMTime(t)];
    if (imgVal == nil) {
      [results addObject:@""];
      continue;
    }
    CGImageRef img = (__bridge CGImageRef)imgVal;
    const BOOL wrote = writeFrameToURL(img, outputURLs[i]);
    [results addObject:wrote ? (outputURLs[i].path ?: @"") : @""];
  }

  for (id imgVal in imagesByKey.allValues) {
    CGImageRelease((__bridge CGImageRef)imgVal);
  }
  return results;
}

@end
