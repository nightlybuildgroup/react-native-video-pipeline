///
/// Transcoder.mm — see Transcoder.h for the contract.
///

#import "Transcoder.h"

#import "OverlayRenderer.h"
#import "Remuxer+Internal.h"
#import "SynthesizeRunner.h"
#import "SynthesizeRunner+Internal.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include "compose/ProgressEmitter.hpp"
#include "compose/StopToken.hpp"
#include "engine/Transcoder.hpp"

#include <cmath>
#include <cstdint>
#include <memory>
#include <optional>

NSErrorDomain const RNVPTranscoderErrorDomain = @"RNVPTranscoderErrorDomain";

namespace {

NSError *makeError(RNVPTranscoderErrorCode code, NSString *message) {
  return [NSError errorWithDomain:RNVPTranscoderErrorDomain
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
  return AVFileTypeMPEG4;
}

// Conservative per-resolution default bitrate when the caller does not set
// one. width * height * fps / 16 ≈ 0.0625 bits/pixel/frame — plenty of
// headroom at typical fps ranges, and scales linearly with resolution and
// frame rate. Concrete numbers this produces:
//   640 × 480  @ 30 → ~576 kbps
//   1280 × 720 @ 30 → ~1.72 Mbps
//   1920 ×1080 @ 30 → ~3.88 Mbps
//   3840 ×2160 @ 30 → ~15.5 Mbps
NSInteger defaultBitrate(NSInteger width, NSInteger height, double fps) {
  const double bps = static_cast<double>(width) *
                     static_cast<double>(height) * fps / 16.0;
  return static_cast<NSInteger>(std::llround(bps));
}

} // namespace

@implementation RNVPTranscodeTarget

- (instancetype)initWithWidth:(NSInteger)width
                       height:(NSInteger)height
                          fps:(double)fps
                        codec:(RNVPTranscodeCodec)codec
                      bitrate:(NSInteger)bitrate
                       rotate:(NSInteger)rotate
                        flipH:(BOOL)flipH
                        flipV:(BOOL)flipV
                        cropX:(double)cropX
                        cropY:(double)cropY
                    cropWidth:(double)cropWidth
                   cropHeight:(double)cropHeight
                  sourceStart:(double)sourceStart
               sourceDuration:(double)sourceDuration {
  if ((self = [super init])) {
    _width = width;
    _height = height;
    _fps = fps;
    _codec = codec;
    _bitrate = bitrate;
    _rotate = rotate;
    _flipH = flipH;
    _flipV = flipV;
    _cropX = cropX;
    _cropY = cropY;
    _cropWidth = cropWidth;
    _cropHeight = cropHeight;
    _sourceStart = sourceStart;
    _sourceDuration = sourceDuration;
  }
  return self;
}

- (instancetype)initWithWidth:(NSInteger)width
                       height:(NSInteger)height
                          fps:(double)fps
                        codec:(RNVPTranscodeCodec)codec
                      bitrate:(NSInteger)bitrate
                       rotate:(NSInteger)rotate
                        flipH:(BOOL)flipH
                        flipV:(BOOL)flipV
                        cropX:(double)cropX
                        cropY:(double)cropY
                    cropWidth:(double)cropWidth
                   cropHeight:(double)cropHeight {
  return [self initWithWidth:width
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
                 sourceStart:0.0
              sourceDuration:0.0];
}

@end

namespace {

// Helper: translate @p image so its extent origin lands at (0, 0). Safe to
// call when the image is already at the origin — the resulting transform
// collapses to identity.
CIImage *normaliseOrigin(CIImage *image) {
  const CGRect ext = image.extent;
  if (std::fabs(ext.origin.x) < 0.5 && std::fabs(ext.origin.y) < 0.5) {
    return image;
  }
  return [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
                                             -ext.origin.x, -ext.origin.y)];
}

// Compose the full frame pipeline on @p sourceImage: source preferredTransform
// → user crop (source-pixel coordinates, applied before rotation/flip per
// docs/api.md) → user rotation → user flip → scale to target. Returns an image
// whose extent is exactly (0, 0, targetWidth, targetHeight).
CIImage *applyTranscodePipeline(CIImage *sourceImage,
                                CGAffineTransform preferredTransform,
                                RNVPTranscodeTarget *target,
                                NSInteger sourceNaturalWidth,
                                NSInteger sourceNaturalHeight) {
  (void)sourceNaturalWidth;
  (void)sourceNaturalHeight;
  CIImage *image = sourceImage;

  // Crop is expressed in source-pixel coordinates (pre-rotation). CIImage
  // coordinates start at the pixel buffer's natural frame, so the crop rect
  // is applied directly against the current extent.
  if (target.cropWidth > 0.0 && target.cropHeight > 0.0) {
    const CGRect cropRect =
        CGRectMake(target.cropX, target.cropY, target.cropWidth,
                   target.cropHeight);
    image = [image imageByCroppingToRect:cropRect];
    image = normaliseOrigin(image);
  }

  // Apply the source's preferredTransform so the downstream scale/flip steps
  // operate on display-oriented pixels. For AVMuxer-authored fixtures this
  // is the identity (a no-op); camera-captured clips pick up their 90° /
  // 180° / 270° rotation here.
  if (!CGAffineTransformIsIdentity(preferredTransform)) {
    image = [image imageByApplyingTransform:preferredTransform];
    image = normaliseOrigin(image);
  }

  // User rotation override (degrees). CIImage rotates CCW for positive
  // angles; we want CW per the public ClipTransform contract so negate.
  if (target.rotate > 0) {
    const double radians =
        -static_cast<double>(target.rotate) * M_PI / 180.0;
    const CGAffineTransform rot = CGAffineTransformMakeRotation(radians);
    image = [image imageByApplyingTransform:rot];
    image = normaliseOrigin(image);
  }

  // User flip H/V — applied in display-oriented pixels so the output mirrors
  // what a human sees at playback, matching the Remuxer flip contract.
  if (target.flipH || target.flipV) {
    const CGRect pre = image.extent;
    CGAffineTransform flip =
        CGAffineTransformMakeScale(target.flipH ? -1.0 : 1.0,
                                   target.flipV ? -1.0 : 1.0);
    if (target.flipH) {
      flip = CGAffineTransformTranslate(flip, -pre.size.width, 0);
    }
    if (target.flipV) {
      flip = CGAffineTransformTranslate(flip, 0, -pre.size.height);
    }
    image = [image imageByApplyingTransform:flip];
    image = normaliseOrigin(image);
  }

  // Final scale to exactly the encoder target dimensions. "Exactly" means
  // non-uniform scaling is acceptable — callers that care about aspect
  // preservation should set the crop to match, or use the remux flip path
  // when only rotation is needed.
  const CGRect preScale = image.extent;
  if (preScale.size.width > 0 && preScale.size.height > 0) {
    const double sx =
        static_cast<double>(target.width) / preScale.size.width;
    const double sy =
        static_cast<double>(target.height) / preScale.size.height;
    const CGAffineTransform scale = CGAffineTransformMakeScale(sx, sy);
    image = [image imageByApplyingTransform:scale];
    image = normaliseOrigin(image);
  }
  return image;
}

// Pump audio samples from @p audioOutput into @p audioInput, compressed
// passthrough. Bounded-wait ready-spin mirrors the remux pumper.
//
// On a trim window (@p hasWindow == YES) the audio is read from a dedicated
// reader whose timeRange is already bounded to the window (see the caller), so
// content selection is handled upstream — splitting a batched AAC buffer here
// is impossible without re-encoding. This pump's only windowing job is to
// rebase: it anchors on the first kept packet's PTS and shifts every packet by
// it so audio starts at t=0, aligned with the video track (itself rebased to
// start at 0). Without the shift the windowed audio would sit at the source
// timeline (~windowStart) while video sits at 0, desyncing A/V.
BOOL pumpAudioPassthrough(AVAssetReaderTrackOutput *audioOutput,
                          AVAssetWriterInput *audioInput,
                          AVAssetReader *audioReader, AVAssetWriter *writer,
                          BOOL hasWindow,
                          NSError *_Nullable __autoreleasing *error) {
  static const NSTimeInterval kReadyTimeout = 30.0;
  CMTime shift = kCMTimeInvalid;  // anchored to the first kept packet's PTS
  while (YES) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kReadyTimeout];
    while (!audioInput.readyForMoreMediaData &&
           [NSDate.date compare:deadline] == NSOrderedAscending) {
      [NSThread sleepForTimeInterval:0.001];
    }
    if (!audioInput.readyForMoreMediaData) {
      if (error) {
        *error = writer.error
                     ?: makeError(RNVPTranscoderErrorCodeWriterFailed,
                                  @"Audio input did not become ready within "
                                  @"30s.");
      }
      return NO;
    }
    CMSampleBufferRef sample = [audioOutput copyNextSampleBuffer];
    if (sample == NULL) {
      if (audioReader.status == AVAssetReaderStatusFailed) {
        if (error) {
          *error = audioReader.error
                       ?: makeError(RNVPTranscoderErrorCodeSourceCorrupted,
                                    @"Audio reader entered the Failed state.");
        }
        return NO;
      }
      return YES;
    }

    if (hasWindow) {
      const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
      if (!CMTIME_IS_VALID(shift)) shift = CMTIME_IS_VALID(pts) ? pts
                                                                : kCMTimeZero;
      CMItemCount timingCount = 0;
      CMSampleBufferGetSampleTimingInfoArray(sample, 0, NULL, &timingCount);
      CMSampleTimingInfo stackTimings[1];
      CMSampleTimingInfo *timings = stackTimings;
      BOOL heapTimings = NO;
      if (timingCount > 1) {
        timings = (CMSampleTimingInfo *)malloc(sizeof(CMSampleTimingInfo) *
                                               timingCount);
        heapTimings = YES;
      } else {
        timingCount = 1;
      }
      if (CMSampleBufferGetSampleTimingInfoArray(sample, timingCount, timings,
                                                 &timingCount) != noErr) {
        // Fall back to the buffer-level timing if the array form is refused.
        timings[0] = (CMSampleTimingInfo){
            .duration = CMSampleBufferGetDuration(sample),
            .presentationTimeStamp = pts,
            .decodeTimeStamp = kCMTimeInvalid};
        timingCount = 1;
      }
      for (CMItemCount i = 0; i < timingCount; i++) {
        if (CMTIME_IS_VALID(timings[i].presentationTimeStamp)) {
          timings[i].presentationTimeStamp = CMTimeMaximum(
              kCMTimeZero,
              CMTimeSubtract(timings[i].presentationTimeStamp, shift));
        }
        if (CMTIME_IS_VALID(timings[i].decodeTimeStamp)) {
          timings[i].decodeTimeStamp = CMTimeMaximum(
              kCMTimeZero, CMTimeSubtract(timings[i].decodeTimeStamp, shift));
        }
      }
      CMSampleBufferRef shifted = NULL;
      const OSStatus copyStatus = CMSampleBufferCreateCopyWithNewTiming(
          kCFAllocatorDefault, sample, timingCount, timings, &shifted);
      if (heapTimings) free(timings);
      CFRelease(sample);
      if (copyStatus != noErr || shifted == NULL) {
        if (error) {
          *error = makeError(RNVPTranscoderErrorCodeWriterFailed,
                             @"Failed to retime windowed audio sample.");
        }
        return NO;
      }
      sample = shifted;
    }

    const BOOL ok = [audioInput appendSampleBuffer:sample];
    CFRelease(sample);
    if (!ok) {
      if (error) {
        *error = writer.error
                     ?: makeError(RNVPTranscoderErrorCodeWriterFailed,
                                  @"Writer rejected audio passthrough sample.");
      }
      return NO;
    }
  }
}

} // namespace

@implementation RNVPTranscoder

+ (BOOL)transcodeFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                  target:(RNVPTranscodeTarget *)target
                overlays:(nullable NSArray *)overlays
                metadata:(nullable RNVPStampMetadata *)metadata
                    stop:(nullable RNVPStopToken *)stopToken
                progress:(nullable RNVPTranscoderProgressBlock)progress
                   error:(NSError *_Nullable __autoreleasing *)error {
  const std::shared_ptr<margelo::nitro::videopipeline::StopToken> stop =
      stopToken != nil
          ? [stopToken cpp]
          : std::shared_ptr<margelo::nitro::videopipeline::StopToken>();

  // Pre-abort shortcut — don't open anything.
  if (stop && stop->abortRequested()) {
    if (error) {
      *error = makeError(RNVPTranscoderErrorCodeCancelled,
                         @"Transcode aborted before it started.");
    }
    return NO;
  }

  if (![[NSFileManager defaultManager] fileExistsAtPath:sourceURL.path]) {
    if (error) {
      *error = makeError(
          RNVPTranscoderErrorCodeNotFound,
          [NSString stringWithFormat:@"No file at %@", sourceURL.path]);
    }
    return NO;
  }

  AVURLAsset *asset = [AVURLAsset assetWithURL:sourceURL];
  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (videoTracks.count == 0) {
    if (error) {
      *error = makeError(RNVPTranscoderErrorCodeSourceCorrupted,
                         @"Source has no video track.");
    }
    return NO;
  }
  AVAssetTrack *videoTrack = videoTracks.firstObject;
  const CGSize naturalSize = videoTrack.naturalSize;
  const double sourceDurationSec = CMTimeGetSeconds(asset.duration);

  // Source trim window. `sourceStart` defaults to 0; `sourceDuration <= 0`
  // means "to the end of the source". End-past-EOF is clamped (matches the
  // remux trim leniency). When the window is the full source, `hasWindow` is
  // NO and the reader reads everything — identical to the pre-trim behavior.
  const double windowStart = target.sourceStart > 0.0 ? target.sourceStart : 0.0;
  double windowDuration = target.sourceDuration > 0.0
                              ? target.sourceDuration
                              : (sourceDurationSec - windowStart);
  if (windowStart + windowDuration > sourceDurationSec) {
    windowDuration = sourceDurationSec - windowStart;
  }
  const BOOL hasWindow =
      windowStart > 1e-3 ||
      (target.sourceDuration > 0.0 && windowDuration + 1e-3 < sourceDurationSec);
  // Duration of the encoded output, used for the progress frame-count estimate.
  const double effectiveDurationSec = hasWindow ? windowDuration
                                                : sourceDurationSec;

  // --- Validate target against source ---------------------------------------
  margelo::nitro::videopipeline::TranscodeTarget cppTarget;
  cppTarget.width = static_cast<int>(target.width);
  cppTarget.height = static_cast<int>(target.height);
  cppTarget.fps = target.fps;
  cppTarget.codec = target.codec == RNVPTranscodeCodecHEVC
                        ? margelo::nitro::videopipeline::TranscodeCodec::HEVC
                        : margelo::nitro::videopipeline::TranscodeCodec::H264;
  if (target.bitrate > 0) {
    cppTarget.bitrate = static_cast<int>(target.bitrate);
  }
  if (target.rotate >= 0) {
    cppTarget.rotate = static_cast<int>(target.rotate);
  }
  cppTarget.flipH = target.flipH == YES;
  cppTarget.flipV = target.flipV == YES;
  if (target.cropWidth > 0.0 && target.cropHeight > 0.0) {
    cppTarget.crop = margelo::nitro::videopipeline::TranscodeCrop{
        target.cropX, target.cropY, target.cropWidth, target.cropHeight};
  }
  cppTarget.sourceStart = windowStart;
  if (target.sourceDuration > 0.0) {
    cppTarget.sourceDuration = windowDuration;
  }
  margelo::nitro::videopipeline::TranscodeSourceProbe probe{
      static_cast<int>(std::lround(naturalSize.width)),
      static_cast<int>(std::lround(naturalSize.height)),
      sourceDurationSec};
  auto rejection = margelo::nitro::videopipeline::describeTranscodeRejection(
      cppTarget, std::optional<margelo::nitro::videopipeline::
                                   TranscodeSourceProbe>(probe));
  if (rejection.has_value()) {
    if (error) {
      *error = makeError(RNVPTranscoderErrorCodeInvalidSpec,
                         utf8(*rejection));
    }
    return NO;
  }

  // --- Set up reader --------------------------------------------------------
  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                         error:&readerError];
  // NOTE: we intentionally do NOT set reader.timeRange for the trim window.
  // A timeRange both snaps its start back to the preceding sync sample *and*
  // rebases the emitted sample PTS, which makes frame-exact gating by source
  // PTS impossible. Instead the encode loop reads the full source and gates
  // each decoded frame by its (un-rebased) source PTS — see the gate below.
  if (reader == nil) {
    if (error) {
      *error = readerError
                   ?: makeError(RNVPTranscoderErrorCodeSourceCorrupted,
                                @"AVAssetReader init failed.");
    }
    return NO;
  }

  NSDictionary<NSString *, id> *decompressSettings = @{
    (NSString *)kCVPixelBufferPixelFormatTypeKey :
        @(kCVPixelFormatType_32BGRA),
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  AVAssetReaderTrackOutput *videoOutput =
      [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack
                                       outputSettings:decompressSettings];
  videoOutput.alwaysCopiesSampleData = NO;
  if (![reader canAddOutput:videoOutput]) {
    if (error) {
      *error = makeError(RNVPTranscoderErrorCodeSourceCorrupted,
                         @"AVAssetReader refused decompressed video output.");
    }
    return NO;
  }
  [reader addOutput:videoOutput];

  // Audio passthrough rides a *dedicated* reader so its trim window can be set
  // via timeRange without disturbing the video reader (which must read the full
  // source and gate frames by PTS — see the note above). On a window the
  // timeRange bounds the audio to [windowStart, windowDuration); the pump then
  // rebases the emitted packets to start at 0. The two readers run
  // sequentially (video loop fully drains before the audio pump starts), so
  // there is no concurrent-read contention on the asset.
  AVAssetReaderTrackOutput *audioOutput = nil;
  AVAssetReader *audioReader = nil;
  NSArray<AVAssetTrack *> *audioTracks =
      [asset tracksWithMediaType:AVMediaTypeAudio];
  if (audioTracks.count > 0) {
    NSError *audioReaderError = nil;
    audioReader = [[AVAssetReader alloc] initWithAsset:asset
                                                 error:&audioReaderError];
    if (audioReader != nil) {
      if (hasWindow) {
        audioReader.timeRange = CMTimeRangeMake(
            CMTimeMakeWithSeconds(windowStart, 90000),
            CMTimeMakeWithSeconds(windowDuration, 90000));
      }
      AVAssetReaderTrackOutput *candidate =
          [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTracks.firstObject
                                           outputSettings:nil];
      if ([audioReader canAddOutput:candidate]) {
        [audioReader addOutput:candidate];
        audioOutput = candidate;
      } else {
        audioReader = nil;
      }
    }
  }

  // --- Set up writer --------------------------------------------------------
  [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

  NSError *writerError = nil;
  AVAssetWriter *writer =
      [[AVAssetWriter alloc] initWithURL:outputURL
                                fileType:fileTypeForOutputURL(outputURL)
                                   error:&writerError];
  if (writer == nil) {
    if (error) {
      *error = writerError
                   ?: makeError(RNVPTranscoderErrorCodeWriterFailed,
                                @"AVAssetWriter init failed.");
    }
    return NO;
  }
  // Container-level metadata: forward the source's bag verbatim when no
  // stamp is supplied (T033/T034/T035 overlay-only path); when T036's stamp
  // router routes here, merge the caller's stamp on top via the shared
  // helper from the Remuxer translation unit so watermark + GPS/software
  // emit the same metadata layout as the metadata-only remux path.
  writer.metadata = metadata != nil
                        ? [metadata mergedWithSourceMetadata:asset.metadata]
                        : asset.metadata;

  const NSInteger bitrate =
      target.bitrate > 0 ? target.bitrate
                         : defaultBitrate(target.width, target.height,
                                          target.fps);
  NSString *const codecKey = target.codec == RNVPTranscodeCodecHEVC
                                 ? AVVideoCodecTypeHEVC
                                 : AVVideoCodecTypeH264;
  NSMutableDictionary<NSString *, id> *compressionProps =
      [NSMutableDictionary dictionaryWithDictionary:@{
        AVVideoAverageBitRateKey : @(bitrate),
        AVVideoExpectedSourceFrameRateKey : @(target.fps),
      }];
  if (target.codec == RNVPTranscodeCodecH264) {
    compressionProps[AVVideoProfileLevelKey] =
        AVVideoProfileLevelH264HighAutoLevel;
  }
  NSDictionary<NSString *, id> *videoSettings = @{
    AVVideoCodecKey : codecKey,
    AVVideoWidthKey : @(target.width),
    AVVideoHeightKey : @(target.height),
    AVVideoCompressionPropertiesKey : compressionProps,
  };
  AVAssetWriterInput *videoInput =
      [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                         outputSettings:videoSettings];
  videoInput.expectsMediaDataInRealTime = NO;
  if (![writer canAddInput:videoInput]) {
    if (error) {
      *error = makeError(RNVPTranscoderErrorCodeWriterFailed,
                         @"AVAssetWriter refused encoded video input.");
    }
    return NO;
  }
  [writer addInput:videoInput];

  NSDictionary<NSString *, id> *pixelAttrs = @{
    (NSString *)kCVPixelBufferPixelFormatTypeKey :
        @(kCVPixelFormatType_32BGRA),
    (NSString *)kCVPixelBufferWidthKey : @(target.width),
    (NSString *)kCVPixelBufferHeightKey : @(target.height),
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  AVAssetWriterInputPixelBufferAdaptor *adaptor =
      [[AVAssetWriterInputPixelBufferAdaptor alloc]
          initWithAssetWriterInput:videoInput
          sourcePixelBufferAttributes:pixelAttrs];

  AVAssetWriterInput *audioInput = nil;
  if (audioOutput != nil) {
    AVAssetTrack *audioTrack = audioTracks.firstObject;
    CMFormatDescriptionRef audioFormat = NULL;
    if (audioTrack.formatDescriptions.count > 0) {
      audioFormat = (__bridge CMFormatDescriptionRef)
          audioTrack.formatDescriptions.firstObject;
    }
    AVAssetWriterInput *candidate =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                           outputSettings:nil
                                         sourceFormatHint:audioFormat];
    candidate.expectsMediaDataInRealTime = NO;
    if ([writer canAddInput:candidate]) {
      [writer addInput:candidate];
      audioInput = candidate;
    } else {
      audioOutput = nil;
      audioReader = nil;
    }
  }

  if (![writer startWriting]) {
    if (error) {
      *error = writer.error
                   ?: makeError(RNVPTranscoderErrorCodeWriterFailed,
                                @"AVAssetWriter startWriting failed.");
    }
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    return NO;
  }
  [writer startSessionAtSourceTime:kCMTimeZero];

  if (![reader startReading]) {
    if (error) {
      *error = reader.error
                   ?: makeError(RNVPTranscoderErrorCodeSourceCorrupted,
                                @"AVAssetReader startReading failed.");
    }
    [writer cancelWriting];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    return NO;
  }

  // --- Progress emitter ----------------------------------------------------
  // Target total ≈ source duration × target.fps. Exact frame count is not
  // knowable until we've finished reading (sample drops, decoder latency)
  // but the estimate is plenty accurate for a UI progress bar — the T033
  // mapping is one source sample → one output sample, so the actual delta
  // sits within ±2 frames on every fixture in the test suite.
  RNVPTranscoderProgressBlock progressCopy = [progress copy];
  std::optional<margelo::nitro::videopipeline::ProgressEmitter> emitter;
  if (progressCopy != nil) {
    const double estimatedFrames =
        std::max(1.0, std::round(effectiveDurationSec * target.fps));
    emitter.emplace(
        [progressCopy](double framesCompleted,
                       std::optional<double> nbFrames, double elapsedMs,
                       std::optional<double> etaMs) {
          const BOOL nbValid = nbFrames.has_value() ? YES : NO;
          const BOOL etaValid = etaMs.has_value() ? YES : NO;
          progressCopy(framesCompleted, nbValid,
                       nbFrames.value_or(0.0), elapsedMs, etaValid,
                       etaMs.value_or(0.0));
        },
        std::optional<double>(estimatedFrames));
    emitter->start();
  }

  // --- Build overlay renderer (pre-rasterizes every image overlay once) ----
  // Happens AFTER writer startWriting so a load failure reports back to the
  // caller without leaving a zombie AVAssetWriter in the `Unknown` state.
  RNVPOverlayRenderer *overlayRenderer = nil;
  if (overlays.count > 0) {
    NSError *overlayErr = nil;
    overlayRenderer = [[RNVPOverlayRenderer alloc]
        initWithOverlays:overlays
              targetSize:CGSizeMake(target.width, target.height)
                   error:&overlayErr];
    if (overlayRenderer == nil) {
      [writer cancelWriting];
      [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
      if (error) {
        // Surface every overlay-renderer failure as InvalidSpec from the
        // transcoder's perspective — the caller passed bad overlay input.
        const NSInteger originalCode = overlayErr.code;
        const NSString *originalMessage =
            overlayErr.localizedDescription ?: @"(nil)";
        *error = makeError(RNVPTranscoderErrorCodeInvalidSpec,
                           [NSString stringWithFormat:
                                         @"overlay prep failed (code %ld): %@",
                                         (long)originalCode, originalMessage]);
      }
      return NO;
    }
  }

  // --- Encode loop ----------------------------------------------------------
  // Default CIContext (GPU-backed on both iOS and macOS). The software
  // renderer option was tried during T033 development but caused intermittent
  // hangs inside `render:toCVPixelBuffer:` on the macOS-host yarn test:native
  // path — the GPU path is deterministic at every fixture size exercised in
  // the XCTests.
  CIContext *ciContext = [CIContext contextWithOptions:nil];
  // `adaptor.pixelBufferPool` is the canonical fast-path source for
  // destination buffers but we deliberately allocate buffers directly via
  // `CVPixelBufferCreate` — macOS host runs of T033 produced intermittent
  // deadlocks when the pool's internal high-water mark (default ~4) pinched
  // against CIContext's render back-pressure. Per-frame allocation adds a
  // few bytes of overhead at the fixture sizes we test but eliminates the
  // pool-and-encoder ordering dependency entirely.
  int32_t outputIndex = 0;
  const CGAffineTransform preferredTransform = videoTrack.preferredTransform;
  const NSInteger sourceW = static_cast<NSInteger>(std::lround(naturalSize.width));
  const NSInteger sourceH = static_cast<NSInteger>(std::lround(naturalSize.height));

  NSError *loopError = nil;
  BOOL loopAborted = NO;
  static const NSTimeInterval kReadyTimeout = 30.0;

  while (YES) {
    // Poll the stop token at the top of each iteration — before any work for
    // this frame starts. Worst-case latency between a `cancelRender` and the
    // loop noticing is one frame's worth of processing (<33ms at 30fps on
    // real hardware), well inside the 500ms abort budget from US7.
    if (stop && stop->abortRequested()) {
      loopAborted = YES;
      break;
    }

    // Wait for the encoder to accept another frame. Back-pressure on the
    // macOS host is the dominant cost of the loop on tiny fixtures — mirror
    // the remux pumper's 30s bound so a wedged writer fails fast. Poll the
    // stop token on every 1ms tick so an abort arriving mid-back-pressure
    // breaks out without waiting for the encoder to drain.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kReadyTimeout];
    while (!videoInput.readyForMoreMediaData &&
           [NSDate.date compare:deadline] == NSOrderedAscending) {
      if (stop && stop->abortRequested()) {
        loopAborted = YES;
        break;
      }
      if (writer.status == AVAssetWriterStatusFailed) break;
      [NSThread sleepForTimeInterval:0.001];
    }
    if (loopAborted) break;
    if (!videoInput.readyForMoreMediaData) {
      loopError = writer.error
                      ?: makeError(RNVPTranscoderErrorCodeWriterFailed,
                                   [NSString stringWithFormat:
                                       @"Video encoder did not become ready "
                                       @"within 30s "
                                       @"(writer.status=%ld, "
                                       @"reader.status=%ld, "
                                       @"framesPushed=%d, "
                                       @"target=%ldx%ld@%.2f %@ %ldbps, "
                                       @"writerErr=%@).",
                                       (long)writer.status,
                                       (long)reader.status,
                                       outputIndex,
                                       (long)target.width,
                                       (long)target.height,
                                       target.fps,
                                       target.codec == RNVPTranscodeCodecHEVC
                                           ? @"HEVC" : @"H264",
                                       (long)(target.bitrate > 0
                                           ? target.bitrate
                                           : defaultBitrate(target.width,
                                                            target.height,
                                                            target.fps)),
                                       writer.error
                                           ?: (id)[NSNull null]]);
      break;
    }

    CMSampleBufferRef sample = [videoOutput copyNextSampleBuffer];
    if (sample == NULL) {
      if (reader.status == AVAssetReaderStatusFailed) {
        loopError = reader.error
                        ?: makeError(RNVPTranscoderErrorCodeSourceCorrupted,
                                     @"AVAssetReader entered the Failed "
                                     @"state.");
      }
      break;
    }
    // Frame-exact trim gating. AVAssetReader's timeRange snaps its start back
    // to a sync sample, so drop decoded frames before the window and stop once
    // we pass the window end. `epsilon` is half a source frame so boundary PTS
    // land inside the window. No-op when `hasWindow` is NO.
    if (hasWindow) {
      const double ptsSec =
          CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
      const double epsilon = 0.5 / std::max(1.0, target.fps);
      if (ptsSec < windowStart - epsilon) {
        CFRelease(sample);
        continue;  // pre-roll before the window start
      }
      if (ptsSec >= windowStart + windowDuration - epsilon) {
        CFRelease(sample);
        break;  // past the window end
      }
    }
    CVPixelBufferRef src = CMSampleBufferGetImageBuffer(sample);
    if (src == NULL) {
      CFRelease(sample);
      loopError = makeError(RNVPTranscoderErrorCodeSourceCorrupted,
                            @"Decoded sample has no image buffer.");
      break;
    }

    @autoreleasepool {
      CIImage *srcImage = [CIImage imageWithCVPixelBuffer:src];
      CIImage *rendered = applyTranscodePipeline(
          srcImage, preferredTransform, target, sourceW, sourceH);

      // Output-timeline time for this frame drives overlay time-range gating.
      // Matches the PTS computation below so a viewer sees overlays ticking
      // in sync with the encoded frames.
      const double frameTimeSec =
          static_cast<double>(outputIndex) / target.fps;
      if (overlayRenderer != nil) {
        rendered = [overlayRenderer applyToFrame:rendered
                                       atTimeSec:frameTimeSec];
      }

      CVPixelBufferRef dst = NULL;
      NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey :
            @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
      };
      CFDictionaryRef attrsCF = (__bridge CFDictionaryRef)attrs;
      const CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                                  (size_t)target.width,
                                                  (size_t)target.height,
                                                  kCVPixelFormatType_32BGRA,
                                                  attrsCF, &dst);
      if (status != kCVReturnSuccess || dst == NULL) {
        CFRelease(sample);
        loopError = makeError(
            RNVPTranscoderErrorCodeEncoderFailure,
            @"Failed to acquire a destination pixel buffer.");
        break;
      }

      [ciContext render:rendered
           toCVPixelBuffer:dst
                    bounds:CGRectMake(0, 0, target.width, target.height)
                colorSpace:nil];

      // Output PTS = outputIndex / target.fps. Integer-fps common case uses
      // the integer fps directly as timescale so there's no float error; a
      // non-integer fps (rare in v0.1 — no consumer needs 29.97/59.94 yet)
      // falls back to a 90 000 Hz timebase for sub-millisecond accuracy.
      const int32_t intFps =
          static_cast<int32_t>(std::llround(target.fps));
      CMTime pts;
      if (std::fabs(target.fps - static_cast<double>(intFps)) < 1e-6) {
        pts = CMTimeMake(outputIndex, intFps);
      } else {
        const int32_t kTimescale = 90000;
        const int64_t value = static_cast<int64_t>(
            std::llround(static_cast<double>(outputIndex) *
                         static_cast<double>(kTimescale) / target.fps));
        pts = CMTimeMake(value, kTimescale);
      }

      const BOOL appended = [adaptor appendPixelBuffer:dst
                                   withPresentationTime:pts];
      CVPixelBufferRelease(dst);
      if (!appended) {
        loopError = writer.error
                        ?: makeError(RNVPTranscoderErrorCodeEncoderFailure,
                                     @"Pixel buffer adaptor rejected the "
                                     @"encoded frame.");
        CFRelease(sample);
        break;
      }
      ++outputIndex;
      if (emitter.has_value()) {
        emitter->report(static_cast<double>(outputIndex));
      }
    }

    CFRelease(sample);
  }

  [videoInput markAsFinished];

  if (loopAborted) {
    if (audioInput != nil) [audioInput markAsFinished];
    [writer cancelWriting];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    if (error) {
      *error = makeError(RNVPTranscoderErrorCodeCancelled,
                         @"Transcode aborted.");
    }
    return NO;
  }

  if (loopError != nil) {
    if (audioInput != nil) [audioInput markAsFinished];
    [writer cancelWriting];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    if (error) *error = loopError;
    return NO;
  }

  // --- Audio passthrough ----------------------------------------------------
  // Start the dedicated audio reader now — the video loop has fully drained, so
  // the two readers never read the asset concurrently.
  if (audioInput != nil && audioOutput != nil && audioReader != nil &&
      ![audioReader startReading]) {
    [audioInput markAsFinished];
    [writer cancelWriting];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    if (error) {
      *error = audioReader.error
                   ?: makeError(RNVPTranscoderErrorCodeSourceCorrupted,
                                @"Audio reader startReading failed.");
    }
    return NO;
  }
  if (audioInput != nil && audioOutput != nil) {
    NSError *audioErr = nil;
    if (!pumpAudioPassthrough(audioOutput, audioInput, audioReader, writer,
                              hasWindow, &audioErr)) {
      [audioInput markAsFinished];
      [writer cancelWriting];
      [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
      if (error) *error = audioErr;
      return NO;
    }
    [audioInput markAsFinished];
  }

  // Compute the end-of-session PTS from the last written output frame. The
  // writer needs this to emit a sensible duration in the output container.
  const int32_t intFps = static_cast<int32_t>(std::llround(target.fps));
  CMTime endTime;
  if (std::fabs(target.fps - static_cast<double>(intFps)) < 1e-6 &&
      intFps > 0) {
    endTime = CMTimeMake(outputIndex, intFps);
  } else {
    const int32_t kTimescale = 90000;
    const int64_t value = static_cast<int64_t>(
        std::llround(static_cast<double>(outputIndex) *
                     static_cast<double>(kTimescale) / target.fps));
    endTime = CMTimeMake(value, kTimescale);
  }
  [writer endSessionAtSourceTime:endTime];

  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [writer finishWritingWithCompletionHandler:^{
    dispatch_semaphore_signal(done);
  }];
  const long timedOut = dispatch_semaphore_wait(
      done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)));
  if (timedOut != 0) {
    if (error) {
      *error = makeError(RNVPTranscoderErrorCodeWriterFailed,
                         @"AVAssetWriter.finishWriting did not complete "
                         @"within 60s.");
    }
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    return NO;
  }
  if (writer.status != AVAssetWriterStatusCompleted) {
    if (error) {
      *error = writer.error
                   ?: makeError(RNVPTranscoderErrorCodeWriterFailed,
                                @"AVAssetWriter did not reach the Completed "
                                @"status.");
    }
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    return NO;
  }
  if (emitter.has_value()) {
    // Lock in the final count so the consumer sees
    // `framesCompleted == nbFrames` and `estimatedRemainingMs == 0` on the
    // last tick. The earlier estimate was duration×fps; the definitive
    // count is `outputIndex` now that the loop has drained.
    emitter->updateNbFrames(static_cast<double>(outputIndex));
    emitter->finalize(static_cast<double>(outputIndex));
  }
  return YES;
}

@end
