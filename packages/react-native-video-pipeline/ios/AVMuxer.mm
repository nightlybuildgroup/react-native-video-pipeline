///
/// AVMuxer.mm — see AVMuxer.h for the contract.
///

#import "AVMuxer.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

NSErrorDomain const RNVPAVMuxerErrorDomain = @"RNVPAVMuxerErrorDomain";

namespace {

constexpr Float64 kAudioSampleRate = 44100.0;
constexpr UInt32 kAudioChannelCount = 1;
constexpr UInt32 kAudioBytesPerSample = sizeof(int16_t);

NSError *makeError(RNVPAVMuxerErrorCode code, NSString *message) {
  return [NSError errorWithDomain:RNVPAVMuxerErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

} // namespace

@implementation RNVPAVMuxer {
  AVAssetWriter *_writer;
  AVAssetWriterInput *_videoInput;
  AVAssetWriterInputPixelBufferAdaptor *_videoAdaptor;
  AVAssetWriterInput *_audioInput;
  CMAudioFormatDescriptionRef _audioFormat;
  CMTime _lastVideoPts;
  NSInteger _fps;
  BOOL _opened;
  BOOL _closed;
}

- (void)dealloc {
  if (_audioFormat != NULL) {
    CFRelease(_audioFormat);
    _audioFormat = NULL;
  }
}

- (BOOL)openAtPath:(NSString *)path
             width:(NSInteger)width
            height:(NSInteger)height
               fps:(NSInteger)fps
             error:(NSError *_Nullable __autoreleasing *)error {
  return [self openAtPath:path
                    width:width
                   height:height
                      fps:fps
                 withAudio:YES
                  metadata:nil
                    error:error];
}

- (BOOL)openVideoOnlyAtPath:(NSString *)path
                      width:(NSInteger)width
                     height:(NSInteger)height
                        fps:(NSInteger)fps
                      error:(NSError *_Nullable __autoreleasing *)error {
  return [self openAtPath:path
                    width:width
                   height:height
                      fps:fps
                 withAudio:NO
                  metadata:nil
                    error:error];
}

- (BOOL)openVideoOnlyAtPath:(NSString *)path
                      width:(NSInteger)width
                     height:(NSInteger)height
                        fps:(NSInteger)fps
                   metadata:(NSArray<AVMetadataItem *> *)metadata
                      error:(NSError *_Nullable __autoreleasing *)error {
  return [self openAtPath:path
                    width:width
                   height:height
                      fps:fps
                 withAudio:NO
                  metadata:metadata
                    error:error];
}

- (BOOL)openAtPath:(NSString *)path
             width:(NSInteger)width
            height:(NSInteger)height
               fps:(NSInteger)fps
         withAudio:(BOOL)withAudio
          metadata:(NSArray<AVMetadataItem *> *)metadata
             error:(NSError *_Nullable __autoreleasing *)error {
  if (_opened) {
    if (error) {
      *error = makeError(RNVPAVMuxerErrorCodeInvalidState,
                         @"AVMuxer has already been opened.");
    }
    return NO;
  }
  if (width <= 0 || height <= 0 || fps <= 0) {
    if (error) {
      *error = makeError(RNVPAVMuxerErrorCodeInvalidSpec,
                         @"width, height, and fps must all be positive.");
    }
    return NO;
  }

  NSURL *url = [NSURL fileURLWithPath:path];
  NSError *writerError = nil;
  AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url
                                                    fileType:AVFileTypeMPEG4
                                                       error:&writerError];
  if (writer == nil) {
    if (error) {
      *error = writerError
                   ?: makeError(RNVPAVMuxerErrorCodeWriterFailed,
                                @"AVAssetWriter could not be created.");
    }
    return NO;
  }

  NSDictionary<NSString *, id> *videoSettings = @{
    AVVideoCodecKey : AVVideoCodecTypeH264,
    AVVideoWidthKey : @(width),
    AVVideoHeightKey : @(height),
  };
  AVAssetWriterInput *videoInput =
      [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                         outputSettings:videoSettings];
  videoInput.expectsMediaDataInRealTime = NO;
  if (![writer canAddInput:videoInput]) {
    if (error) {
      *error = makeError(RNVPAVMuxerErrorCodeWriterFailed,
                         @"AVAssetWriter refused the video input.");
    }
    return NO;
  }
  [writer addInput:videoInput];

  NSDictionary<NSString *, id> *pixelBufferAttrs = @{
    (NSString *)kCVPixelBufferPixelFormatTypeKey :
        @(kCVPixelFormatType_32BGRA),
    (NSString *)kCVPixelBufferWidthKey : @(width),
    (NSString *)kCVPixelBufferHeightKey : @(height),
    // IOSurface-backed buffers let the adaptor take ownership without a CPU
    // copy. Empty dict = "default IOSurface attributes". Pool-vended buffers
    // inherit this — required for the zero-copy contract MetalBlit relies on.
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  AVAssetWriterInputPixelBufferAdaptor *adaptor =
      [[AVAssetWriterInputPixelBufferAdaptor alloc]
          initWithAssetWriterInput:videoInput
          sourcePixelBufferAttributes:pixelBufferAttrs];

  AVAssetWriterInput *audioInput = nil;
  CMAudioFormatDescriptionRef audioFormat = NULL;
  if (withAudio) {
    AudioChannelLayout channelLayout = {0};
    channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    NSDictionary<NSString *, id> *audioSettings = @{
      AVFormatIDKey : @(kAudioFormatMPEG4AAC),
      AVNumberOfChannelsKey : @(kAudioChannelCount),
      AVSampleRateKey : @(kAudioSampleRate),
      AVEncoderBitRateKey : @(64000),
      AVChannelLayoutKey : [NSData
          dataWithBytes:&channelLayout
                 length:offsetof(AudioChannelLayout, mChannelDescriptions)],
    };
    audioInput =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                           outputSettings:audioSettings];
    audioInput.expectsMediaDataInRealTime = NO;
    if (![writer canAddInput:audioInput]) {
      if (error) {
        *error = makeError(RNVPAVMuxerErrorCodeWriterFailed,
                           @"AVAssetWriter refused the audio input.");
      }
      return NO;
    }
    [writer addInput:audioInput];

    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = kAudioSampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags =
        kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    asbd.mBitsPerChannel = kAudioBytesPerSample * 8;
    asbd.mChannelsPerFrame = kAudioChannelCount;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = kAudioBytesPerSample * kAudioChannelCount;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame;

    OSStatus status = CMAudioFormatDescriptionCreate(
        kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &audioFormat);
    if (status != noErr) {
      if (error) {
        *error = makeError(
            RNVPAVMuxerErrorCodeWriterFailed,
            [NSString stringWithFormat:
                          @"CMAudioFormatDescriptionCreate failed (status=%d).",
                          (int)status]);
      }
      return NO;
    }
  }

  // Container-level metadata must be set before startWriting — AVAssetWriter
  // rejects mutations once status moves out of Unknown.
  if (metadata != nil && metadata.count > 0) {
    writer.metadata = metadata;
  }

  if (![writer startWriting]) {
    if (audioFormat != NULL) CFRelease(audioFormat);
    if (error) {
      *error = writer.error
                   ?: makeError(RNVPAVMuxerErrorCodeWriterFailed,
                                @"AVAssetWriter startWriting failed.");
    }
    return NO;
  }
  [writer startSessionAtSourceTime:kCMTimeZero];

  _writer = writer;
  _videoInput = videoInput;
  _videoAdaptor = adaptor;
  _audioInput = audioInput;
  _audioFormat = audioFormat;
  _lastVideoPts = kCMTimeInvalid;
  _fps = fps;
  _opened = YES;
  _closed = NO;
  return YES;
}

- (BOOL)videoInputIsReady {
  if (!_opened || _closed) return NO;
  return _videoInput.isReadyForMoreMediaData;
}


- (BOOL)appendPixelBuffer:(CVPixelBufferRef)pixelBuffer
         presentationTime:(CMTime)pts
                    error:(NSError *_Nullable __autoreleasing *)error {
  if (!_opened || _closed) {
    if (error) {
      *error = makeError(RNVPAVMuxerErrorCodeInvalidState,
                         @"AVMuxer.appendPixelBuffer: not open.");
    }
    return NO;
  }
  // Spin until the video input is ready. Bounded so a wedged writer surfaces
  // as a typed error instead of an unbounded hang. 30s is loose on purpose:
  // the simulator encoder back-pressures AVAssetWriterInput when its internal
  // queue fills up (observed in `testSynthesizeOpenStopsOnStopTokenFinish`,
  // which pushes ~50 small frames then waits multiple seconds for the queue
  // to drain), and cold-start initialisation of the first frame can itself
  // take seconds. Genuine hangs are still caught — just not the slow-simulator
  // path. CLAUDE.md's "over 5s is wedged" is a per-test total, not a single
  // appendPixelBuffer bound.
  const NSTimeInterval kReadyDeadline = [NSDate timeIntervalSinceReferenceDate] + 30.0;
  while (!_videoInput.isReadyForMoreMediaData) {
    if ([NSDate timeIntervalSinceReferenceDate] >= kReadyDeadline) {
      if (error) {
        *error = _writer.error
                     ?: makeError(RNVPAVMuxerErrorCodeAppendFailed,
                                  @"AVMuxer.appendPixelBuffer: video input "
                                  @"did not become ready within 30s.");
      }
      return NO;
    }
    [NSThread sleepForTimeInterval:0.001];
  }
  if (![_videoAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:pts]) {
    if (error) {
      *error = _writer.error
                   ?: makeError(RNVPAVMuxerErrorCodeAppendFailed,
                                @"Pixel buffer adaptor rejected the sample.");
    }
    return NO;
  }
  _lastVideoPts = pts;
  return YES;
}

- (BOOL)closeWithError:(NSError *_Nullable __autoreleasing *)error {
  if (!_opened || _closed) {
    if (error) {
      *error = makeError(RNVPAVMuxerErrorCodeInvalidState,
                         @"AVMuxer.close: not open or already closed.");
    }
    return NO;
  }

  if (_audioInput != nil) {
    // Build a silent PCM track spanning [0, lastPts + 1/fps) and let
    // AVAssetWriter's encoder transcode it to AAC.
    CMTime frameDuration = CMTimeMake(1, (int32_t)_fps);
    CMTime videoEnd = CMTimeAdd(CMTIME_IS_VALID(_lastVideoPts) ? _lastVideoPts
                                                               : kCMTimeZero,
                                frameDuration);
    Float64 durationSeconds = CMTimeGetSeconds(videoEnd);
    if (durationSeconds < 0.0) {
      durationSeconds = 0.0;
    }
    UInt32 totalSampleFrames =
        (UInt32)llround(durationSeconds * kAudioSampleRate);

    NSError *audioError = nil;
    if (totalSampleFrames > 0 &&
        ![self appendSilentAudioFrames:totalSampleFrames error:&audioError]) {
      if (error) {
        *error = audioError;
      }
      return NO;
    }
  }

  [_videoInput markAsFinished];
  if (_audioInput != nil) [_audioInput markAsFinished];

  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block BOOL finished = NO;
  [_writer finishWritingWithCompletionHandler:^{
    finished = (self->_writer.status == AVAssetWriterStatusCompleted);
    dispatch_semaphore_signal(done);
  }];
  // Bounded wait — a wedged writer must fail fast instead of hanging the
  // whole test run. 3s is far beyond any legitimate finalize duration in the
  // current test matrix (<1s of video, tiny dimensions).
  const long timedOut = dispatch_semaphore_wait(
      done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)));

  _closed = YES;

  if (timedOut != 0) {
    if (error) {
      *error = _writer.error
                   ?: makeError(RNVPAVMuxerErrorCodeWriterFailed,
                                @"AVAssetWriter.finishWriting did not complete "
                                @"within 3s.");
    }
    return NO;
  }
  if (!finished) {
    if (error) {
      *error = _writer.error
                   ?: makeError(RNVPAVMuxerErrorCodeWriterFailed,
                                @"AVAssetWriter.finishWriting did not reach "
                                @"the Completed status.");
    }
    return NO;
  }
  return YES;
}

- (BOOL)appendSilentAudioFrames:(UInt32)totalSampleFrames
                          error:(NSError *_Nullable __autoreleasing *)error {
  // Emit silence in chunks so very long renders never allocate one giant
  // block buffer up front. 1 second of mono 16-bit PCM = 88 200 bytes.
  constexpr UInt32 kChunkFrames = 44100;
  UInt32 remaining = totalSampleFrames;
  CMTime cursor = kCMTimeZero;

  while (remaining > 0) {
    UInt32 chunk = remaining < kChunkFrames ? remaining : kChunkFrames;
    size_t bytes = (size_t)chunk * kAudioBytesPerSample * kAudioChannelCount;

    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, bytes, kCFAllocatorDefault, NULL, 0, bytes,
        kCMBlockBufferAssureMemoryNowFlag, &block);
    if (status != noErr || block == NULL) {
      if (error) {
        *error = makeError(RNVPAVMuxerErrorCodeAppendFailed,
                           @"CMBlockBufferCreateWithMemoryBlock failed.");
      }
      return NO;
    }
    status = CMBlockBufferFillDataBytes(0, block, 0, bytes);
    if (status != noErr) {
      CFRelease(block);
      if (error) {
        *error = makeError(RNVPAVMuxerErrorCodeAppendFailed,
                           @"CMBlockBufferFillDataBytes failed.");
      }
      return NO;
    }

    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(1, (int32_t)kAudioSampleRate);
    timing.presentationTimeStamp = cursor;
    timing.decodeTimeStamp = kCMTimeInvalid;
    status = CMSampleBufferCreate(kCFAllocatorDefault, block, true, NULL, NULL,
                                  _audioFormat, (CMItemCount)chunk, 1, &timing,
                                  0, NULL, &sample);
    CFRelease(block);
    if (status != noErr || sample == NULL) {
      if (error) {
        *error = makeError(RNVPAVMuxerErrorCodeAppendFailed,
                           @"CMSampleBufferCreate failed for silent audio.");
      }
      return NO;
    }

    while (!_audioInput.isReadyForMoreMediaData) {
      [NSThread sleepForTimeInterval:0.001];
    }
    BOOL ok = [_audioInput appendSampleBuffer:sample];
    CFRelease(sample);
    if (!ok) {
      if (error) {
        *error = _writer.error
                     ?: makeError(RNVPAVMuxerErrorCodeAppendFailed,
                                  @"Audio input rejected a silent sample.");
      }
      return NO;
    }

    cursor = CMTimeAdd(cursor, CMTimeMake(chunk, (int32_t)kAudioSampleRate));
    remaining -= chunk;
  }
  return YES;
}

@end
