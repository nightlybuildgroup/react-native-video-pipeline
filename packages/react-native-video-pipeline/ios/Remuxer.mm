///
/// Remuxer.mm — see Remuxer.h for the contract.
///

#import "Remuxer.h"
#import "Remuxer+Internal.h"
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
  // Bounded wait. The 30-second cap mirrors RNVPAVMuxer's video-input poll
  // — anything longer is a wedged writer, not a slow encoder.
  static const NSTimeInterval kReadyTimeout = 30.0;
  while (YES) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kReadyTimeout];
    while (!input.readyForMoreMediaData &&
           [NSDate.date compare:deadline] == NSOrderedAscending) {
      [NSThread sleepForTimeInterval:0.001];
    }
    if (!input.readyForMoreMediaData) {
      if (error) {
        *error = writer.error
                     ?: makeError(RNVPRemuxerErrorCodeWriterFailed,
                                  @"Writer input did not become ready within "
                                  @"30s.");
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
  AVAssetTrack *videoTrack = videoTracks.firstObject;

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

  // AVAssetWriter rejects an existing file — clear it here so callers don't
  // have to (symmetrical with RNVPSynthesizeRunner).
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

  // Forward container-level metadata verbatim — creation date, location,
  // software, custom keys all round-trip through AVURLAsset.metadata.
  writer.metadata = asset.metadata;

  // Build the source-time window. The reader enforces the end bound; the
  // writer's session + endSession pair mark the same window on the output
  // timeline so AVAssetWriter can emit an edit list that rebases playback
  // to start at 0 in the resulting container.
  const CMTime startTime = CMTimeMakeWithSeconds(startSec, NSEC_PER_SEC);
  CMTime duration = CMTimeMakeWithSeconds(durationSec, NSEC_PER_SEC);
  const CMTime assetEnd = asset.duration;
  const CMTime requestedEnd = CMTimeAdd(startTime, duration);
  if (CMTimeCompare(requestedEnd, assetEnd) > 0) {
    // describeTrimRejection already enforces start+duration <= sourceDuration
    // within a 1ms tolerance; if we're ever-so-slightly past due to rounding,
    // clamp silently so AVAssetReader doesn't reject the range.
    duration = CMTimeSubtract(assetEnd, startTime);
  }
  const CMTime endTime = CMTimeAdd(startTime, duration);
  const CMTimeRange timeRange = CMTimeRangeMake(startTime, duration);

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
  reader.timeRange = timeRange;

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
  // Preserve source rotation by copying the preferredTransform onto the
  // writer input. Identity transforms (typical for AVMuxer-authored files)
  // stay identity; 90°/180°/270°-rotated sources carry their rotation into
  // the output without touching pixel bytes.
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
  [writer startSessionAtSourceTime:startTime];

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

  [writer endSessionAtSourceTime:endTime];

  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [writer finishWritingWithCompletionHandler:^{
    dispatch_semaphore_signal(done);
  }];
  // Generous bound — a 1-minute 4K remux on an iPhone 13 should finish in
  // <2s (US1 acceptance), and the macOS host path runs against sub-second
  // fixtures. 30s is long enough to survive a CI cold start, short enough
  // that a wedged writer fails the xcodebuild per-test budget.
  const long timedOut = dispatch_semaphore_wait(
      done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)));
  if (timedOut != 0) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeWriterFailed,
                         @"AVAssetWriter.finishWriting did not complete "
                         @"within 30s.");
    }
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    return NO;
  }
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

  [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

  NSError *writerError = nil;
  AVAssetWriter *writer =
      [[AVAssetWriter alloc] initWithURL:outputURL
                                fileType:outputType
                                   error:&writerError];
  if (writer == nil) {
    if (error) {
      *error = writerError
                   ?: makeError(RNVPRemuxerErrorCodeWriterFailed,
                                @"AVAssetWriter init failed.");
    }
    return NO;
  }

  // Forward container-level metadata verbatim — same contract as trim.
  writer.metadata = asset.metadata;

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
  videoInput.transform = flipTransformForAxis(
      axis, videoTrack.preferredTransform, videoTrack.naturalSize);
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
  const long timedOut = dispatch_semaphore_wait(
      done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)));
  if (timedOut != 0) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeWriterFailed,
                         @"AVAssetWriter.finishWriting did not complete "
                         @"within 30s.");
    }
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    return NO;
  }
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

NSString *exportPresetForContainer(AVFileType fileType) {
  // AVAssetExportPresetPassthrough re-muxes without re-encoding when the
  // session's outputFileType + the composition's track formats are both
  // supported as-is by the writer. For identical H.264/HEVC sources this
  // is true for both MP4 and MOV.
  (void)fileType;
  return AVAssetExportPresetPassthrough;
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

  // --- Drive the passthrough export ---------------------------------------
  [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

  AVFileType outputType = fileTypeForOutputURL(outputURL);
  AVAssetExportSession *session = [[AVAssetExportSession alloc]
      initWithAsset:composition
         presetName:exportPresetForContainer(outputType)];
  if (session == nil) {
    if (error) {
      *error = makeError(
          RNVPRemuxerErrorCodeWriterFailed,
          @"AVAssetExportSession refused the passthrough preset.");
    }
    return NO;
  }
  session.outputURL = outputURL;
  session.outputFileType = outputType;
  session.shouldOptimizeForNetworkUse = NO;
  // Forward container-level metadata from the first source — matches the
  // trim/flip contract ("metadata round-trips"). Later clips' metadata is
  // dropped; a future merge policy can be defined when stamp() learns about
  // multi-clip inputs.
  session.metadata = assets.firstObject.metadata;

  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  // Watcher: if the caller flips the stop token while the export is in
  // flight, invoke cancelExport. Invalidates itself once the main thread
  // signals `done`, so no additional cleanup is needed after the wait.
  // Poll cadence (50ms) keeps the abort-to-cancelExport latency well under
  // the 500ms budget US7 allows.
  __block BOOL watcherDone = NO;
  if (stop) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,
                                             0),
                   ^{
                     while (!watcherDone) {
                       if (stop->abortRequested()) {
                         [session cancelExport];
                         return;
                       }
                       [NSThread sleepForTimeInterval:0.05];
                     }
                   });
  }
  [session exportAsynchronouslyWithCompletionHandler:^{
    dispatch_semaphore_signal(done);
  }];
  const long timedOut = dispatch_semaphore_wait(
      done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)));
  watcherDone = YES;
  if (timedOut != 0) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeWriterFailed,
                         @"AVAssetExportSession did not complete within 60s.");
    }
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    return NO;
  }
  if (session.status == AVAssetExportSessionStatusCancelled ||
      (stop && stop->abortRequested())) {
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeCancelled,
                         @"Concat aborted.");
    }
    return NO;
  }
  if (session.status != AVAssetExportSessionStatusCompleted) {
    if (error) {
      *error = session.error
                   ?: makeError(RNVPRemuxerErrorCodeWriterFailed,
                                @"AVAssetExportSession did not reach "
                                @"Completed.");
    }
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
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
  const long timedOut = dispatch_semaphore_wait(
      done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)));
  if (timedOut != 0) {
    if (error) {
      *error = makeError(RNVPRemuxerErrorCodeWriterFailed,
                         @"AVAssetWriter.finishWriting did not complete "
                         @"within 30s.");
    }
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    return NO;
  }
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
