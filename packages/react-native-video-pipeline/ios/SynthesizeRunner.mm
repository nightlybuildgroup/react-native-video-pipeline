///
/// SynthesizeRunner.mm — see SynthesizeRunner.h for the contract.
///
/// The FrameSource installed here is a deterministic test pattern: each
/// frame is a flat fill whose RGB triple is a function of the frame index
/// only (see `fillTestPatternRGBA`). Flat frames have ~zero H.264 residual
/// and chroma-subsample cleanly, so the center pixel of frame N decodes
/// back to within ±2/255 of its authored value — the T023 bootstrap
/// self-test relies on that stability to catch synthesize regressions.
/// A real worklet pump (T041+) will replace this callback with a call
/// across the Nitro/Reanimated boundary.
///

#import "SynthesizeRunner.h"
#import "SynthesizeRunner+Internal.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#import "AVMuxer.h"
#import "WorkletFrameBridge.h"
#import "compose/ComposeRunner.hpp"
#import "compose/ProgressEmitter.hpp"
#import "compose/StopToken.hpp"

#include <cmath>
#include <memory>
#include <optional>
#include <string>

NSErrorDomain const RNVPSynthesizeRunnerErrorDomain =
    @"RNVPSynthesizeRunnerErrorDomain";

@implementation RNVPStopToken {
  std::shared_ptr<margelo::nitro::videopipeline::StopToken> _stop;
}

- (instancetype)init {
  if ((self = [super init])) {
    _stop = std::make_shared<margelo::nitro::videopipeline::StopToken>();
  }
  return self;
}

+ (instancetype)tokenFromSharedPtr:
    (std::shared_ptr<margelo::nitro::videopipeline::StopToken>)cpp {
  RNVPStopToken *token = [[RNVPStopToken alloc] init];
  // Overwrite the freshly-allocated inner with the caller's shared_ptr so
  // that any other holder (e.g. the RenderTokenRegistry) sees the same flag
  // memory when it calls requestFinish / requestAbort.
  token->_stop = std::move(cpp);
  return token;
}

- (void)requestFinish {
  _stop->requestFinish();
}

- (void)requestAbort {
  _stop->requestAbort();
}

- (BOOL)finishRequested {
  return _stop->finishRequested() ? YES : NO;
}

- (BOOL)abortRequested {
  return _stop->abortRequested() ? YES : NO;
}

- (const std::shared_ptr<margelo::nitro::videopipeline::StopToken> &)cpp {
  return _stop;
}

@end

namespace {

NSError *errorFromStdString(RNVPSynthesizeRunnerErrorCode code,
                            const std::string &msg) {
  NSString *nsMsg =
      [[NSString alloc] initWithBytes:msg.data()
                               length:msg.size()
                             encoding:NSUTF8StringEncoding] ?: @"(no message)";
  return [NSError
      errorWithDomain:RNVPSynthesizeRunnerErrorDomain
                 code:code
             userInfo:@{NSLocalizedDescriptionKey : nsMsg}];
}

// Flat fill whose RGB triple is purely a function of `frameIndex`. The
// exact formula — (r,g,b) = ((i*11) & 0xff, (i*53) & 0xff, (i*97) & 0xff)
// — is the canonical bootstrap self-test pattern and is mirrored verbatim
// in `__tests__/bootstrap/self-test.ts` and the T023 XCTest canary in
// `apps/bare-example/ios/bareexampleTests/bareexampleTests.m`. If you
// change it here, update both sites together.
bool fillTestPatternRGBA(int frameIndex, uint8_t *dst, std::size_t rowBytes,
                         int width, int height) {
  const uint8_t r = static_cast<uint8_t>((frameIndex * 11) & 0xff);
  const uint8_t g = static_cast<uint8_t>((frameIndex * 53) & 0xff);
  const uint8_t b = static_cast<uint8_t>((frameIndex * 97) & 0xff);
  for (int y = 0; y < height; ++y) {
    uint8_t *row = dst + static_cast<std::size_t>(y) * rowBytes;
    for (int x = 0; x < width; ++x) {
      row[x * 4 + 0] = r;
      row[x * 4 + 1] = g;
      row[x * 4 + 2] = b;
      row[x * 4 + 3] = 0xff;
    }
  }
  return true;
}

// Shared error-capture slots used by the sink lambdas. C++ lambdas
// (std::function closures) cannot capture __block-qualified NSError* locals,
// so we hold the slot in a shared_ptr the lambdas copy by value.
struct ErrorSlot { NSError *err = nil; };

// Builds a FrameSink bound to `muxer` + `outputPath`. The three error slots
// are mutated on failure; callers read them after the run to distinguish
// open/append/close errors. `stop` is consulted during the sink's
// ready-wait spin so a finish/abort signal arriving while the encoder is
// back-pressuring can break out immediately; pass `nullptr` for the fixed
// path which has no external stop token.
margelo::nitro::videopipeline::ComposeRunner::FrameSink
buildSink(RNVPAVMuxer *muxer, NSString *outputPath, int width, int height,
          std::shared_ptr<ErrorSlot> openSlot,
          std::shared_ptr<ErrorSlot> frameSlot,
          std::shared_ptr<ErrorSlot> closeSlot,
          std::shared_ptr<margelo::nitro::videopipeline::StopToken> stop) {
  using namespace margelo::nitro::videopipeline;

  ComposeRunner::FrameSink sink;

  sink.open = [muxer, outputPath, openSlot](int w, int h, double f,
                                            std::string &err) -> bool {
    NSError *nsErr = nil;
    const BOOL ok = [muxer openAtPath:outputPath
                                width:w
                               height:h
                                  fps:static_cast<NSInteger>(std::lround(f))
                                error:&nsErr];
    if (!ok) {
      openSlot->err = nsErr;
      err = std::string("AVMuxer.open failed: ") +
            (nsErr.localizedDescription.UTF8String ?: "(nil)");
      return false;
    }
    return true;
  };

  sink.appendFrame = [muxer, frameSlot, width, height,
                      stop](const uint8_t *rgba, std::size_t rowBytes,
                            double ptsSec, std::string &err) -> bool {
    // Spin-wait for the encoder to accept another frame — but keep checking
    // the stop token on every tick. On the simulator the H.264 encoder can
    // back-pressure for seconds at a time after the writer's queue fills
    // up (~50 frames at 160×120). There is no wall-clock deadline (issue #32):
    // the wait ends on a real signal only — the encoder draining (readiness),
    // a stop/finish request, or the writer failing (which would otherwise
    // pin readiness at NO forever). The subsequent appendPixelBuffer surfaces
    // the writer's own error in the failure case.
    while (!muxer.videoInputIsReady) {
      if (stop && (stop->abortRequested() || stop->finishRequested())) {
        err = "AVMuxer.append: stop requested during ready-wait";
        return false;
      }
      if (muxer.videoInputFailed) break;
      [NSThread sleepForTimeInterval:0.001];
    }

    NSError *bridgeErr = nil;
    CVPixelBufferRef pb = [RNVPWorkletFrameBridge
        pixelBufferFromBytes:rgba
                       width:width
                      height:height
                    rowBytes:static_cast<NSInteger>(rowBytes)
                      format:RNVPBitmapFormatRGBA8888Premultiplied
                       error:&bridgeErr];
    if (pb == NULL) {
      frameSlot->err = bridgeErr;
      err = std::string("WorkletFrameBridge failed: ") +
            (bridgeErr.localizedDescription.UTF8String ?: "(nil)");
      return false;
    }
    // Nanosecond timebase keeps PTS integer-exact even for awkward fps
    // (e.g. 29.97) should we ever allow non-integer frame rates.
    const CMTime pts =
        CMTimeMake(static_cast<int64_t>(std::llround(ptsSec * 1'000'000'000.0)),
                   1'000'000'000);
    NSError *muxErr = nil;
    const BOOL ok =
        [muxer appendPixelBuffer:pb presentationTime:pts error:&muxErr];
    CVPixelBufferRelease(pb);
    if (!ok) {
      frameSlot->err = muxErr;
      err = std::string("AVMuxer.append failed: ") +
            (muxErr.localizedDescription.UTF8String ?: "(nil)");
      return false;
    }
    return true;
  };

  sink.close = [muxer, closeSlot](std::string &err) -> bool {
    NSError *nsErr = nil;
    const BOOL ok = [muxer closeWithError:&nsErr];
    if (!ok) {
      closeSlot->err = nsErr;
      err = std::string("AVMuxer.close failed: ") +
            (nsErr.localizedDescription.UTF8String ?: "(nil)");
      return false;
    }
    return true;
  };

  return sink;
}

// Wrap a best-fit typed error around whichever slot(s) captured an NSError
// during the run.
void populateErrorFromSlots(NSError *__autoreleasing *error,
                            std::shared_ptr<ErrorSlot> openSlot,
                            std::shared_ptr<ErrorSlot> frameSlot,
                            std::shared_ptr<ErrorSlot> closeSlot,
                            const std::string &runError) {
  if (error == NULL) return;
  if (openSlot->err != nil) {
    *error = [NSError errorWithDomain:RNVPSynthesizeRunnerErrorDomain
                                 code:RNVPSynthesizeRunnerErrorCodeOpenFailed
                             userInfo:@{NSUnderlyingErrorKey : openSlot->err}];
  } else if (frameSlot->err != nil) {
    *error = [NSError errorWithDomain:RNVPSynthesizeRunnerErrorDomain
                                 code:RNVPSynthesizeRunnerErrorCodeFrameFailed
                             userInfo:@{NSUnderlyingErrorKey : frameSlot->err}];
  } else if (closeSlot->err != nil) {
    *error = [NSError errorWithDomain:RNVPSynthesizeRunnerErrorDomain
                                 code:RNVPSynthesizeRunnerErrorCodeCloseFailed
                             userInfo:@{NSUnderlyingErrorKey : closeSlot->err}];
  } else {
    *error = errorFromStdString(RNVPSynthesizeRunnerErrorCodeFrameFailed,
                                runError);
  }
}

} // namespace

@implementation RNVPSynthesizeRunner

+ (BOOL)runFixedWithOutputPath:(NSString *)outputPath
                         width:(NSInteger)width
                        height:(NSInteger)height
                           fps:(double)fps
                       seconds:(double)seconds
                     stopToken:(nullable RNVPStopToken *)stopToken
                      progress:(nullable RNVPProgressBlock)progress
                       aborted:(BOOL *)aborted
                         error:(NSError *__autoreleasing *)error {
  if (aborted != NULL) *aborted = NO;

  if (outputPath.length == 0 || width <= 0 || height <= 0 || fps <= 0.0 ||
      seconds <= 0.0) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:RNVPSynthesizeRunnerErrorDomain
                                   code:RNVPSynthesizeRunnerErrorCodeInvalidSpec
                               userInfo:@{
                                 NSLocalizedDescriptionKey : @"invalid spec"
                               }];
    }
    return NO;
  }

  // AVAssetWriter refuses to overwrite a pre-existing file; callers rarely
  // want sticky state from a prior failed run.
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:outputPath]) {
    [fm removeItemAtPath:outputPath error:NULL];
  }

  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];

  using namespace margelo::nitro::videopipeline;

  const int width_i = static_cast<int>(width);
  const int height_i = static_cast<int>(height);

  ComposeRunner::FixedSpec spec{width_i, height_i, fps, seconds};

  auto source = [width_i, height_i](int frameIndex, uint8_t *dst,
                                    std::size_t rowBytes,
                                    std::string & /*err*/) -> bool {
    return fillTestPatternRGBA(frameIndex, dst, rowBytes, width_i, height_i);
  };

  auto openSlot = std::make_shared<ErrorSlot>();
  auto frameSlot = std::make_shared<ErrorSlot>();
  auto closeSlot = std::make_shared<ErrorSlot>();

  std::shared_ptr<StopToken> stop =
      stopToken != nil ? [stopToken cpp] : std::shared_ptr<StopToken>();

  ComposeRunner::FrameSink sink =
      buildSink(muxer, outputPath, width_i, height_i, openSlot, frameSlot,
                closeSlot, stop);

  // Copy the block into a heap shared_ptr so the C++ std::function captures
  // a strongly-owned reference that survives for the life of the emitter.
  RNVPProgressBlock progressCopy = [progress copy];
  std::optional<ProgressEmitter> emitter;
  if (progressCopy != nil) {
    // fps*seconds → double-valued nbFrames, rounded the same way
    // ComposeRunner::frameCountFor does internally. The emitter also calls
    // updateNbFrames(frameCount) inside runFixed, so this is just an
    // optimisation to seed the initial tick with a definite ETA.
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
        std::optional<double>(static_cast<double>(
            ComposeRunner::frameCountFor(fps, seconds))));
  }

  std::string runError;
  bool wasAborted = false;
  const bool ok = ComposeRunner::runFixed(
      spec, source, sink, runError,
      emitter.has_value() ? &emitter.value() : nullptr,
      stop ? stop.get() : nullptr, &wasAborted);
  if (!ok) {
    populateErrorFromSlots(error, openSlot, frameSlot, closeSlot, runError);
    return NO;
  }
  if (wasAborted) {
    // Abort discards the output — mirrors the runOpen contract. ComposeRunner
    // skipped sink.close on the abort path, so just remove the partial file
    // AVAssetWriter may have left on disk.
    [fm removeItemAtPath:outputPath error:NULL];
    if (aborted != NULL) *aborted = YES;
  }
  return YES;
}

+ (BOOL)runOpenWithOutputPath:(NSString *)outputPath
                        width:(NSInteger)width
                       height:(NSInteger)height
                          fps:(double)fps
                   maxSeconds:(double)maxSeconds
                    stopToken:(RNVPStopToken *)stopToken
                finishOnFrame:(NSInteger)finishOnFrame
                     progress:(nullable RNVPProgressBlock)progress
                framesWritten:(NSInteger *)framesWritten
                      aborted:(BOOL *)aborted
                         error:(NSError *__autoreleasing *)error {
  if (framesWritten != NULL) *framesWritten = 0;
  if (aborted != NULL) *aborted = NO;

  if (outputPath.length == 0 || width <= 0 || height <= 0 || fps <= 0.0 ||
      stopToken == nil) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:RNVPSynthesizeRunnerErrorDomain
                                   code:RNVPSynthesizeRunnerErrorCodeInvalidSpec
                               userInfo:@{
                                 NSLocalizedDescriptionKey : @"invalid spec"
                               }];
    }
    return NO;
  }

  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:outputPath]) {
    [fm removeItemAtPath:outputPath error:NULL];
  }

  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];

  using namespace margelo::nitro::videopipeline;

  const int width_i = static_cast<int>(width);
  const int height_i = static_cast<int>(height);
  const int finishOnFrame_i = static_cast<int>(finishOnFrame);

  ComposeRunner::OpenSpec spec{width_i, height_i, fps, maxSeconds};

  auto source = [width_i, height_i, finishOnFrame_i](int frameIndex,
                                                     uint8_t *dst,
                                                     std::size_t rowBytes,
                                                     bool &shouldFinish,
                                                     std::string & /*err*/) -> bool {
    fillTestPatternRGBA(frameIndex, dst, rowBytes, width_i, height_i);
    // The real worklet pump (T041) will set `shouldFinish` based on the
    // worklet calling `ctx.finish()` on the current frame. Until then, this
    // hook lets XCTests simulate that behaviour deterministically.
    if (finishOnFrame_i >= 0 && frameIndex >= finishOnFrame_i) {
      shouldFinish = true;
    }
    return true;
  };

  auto openSlot = std::make_shared<ErrorSlot>();
  auto frameSlot = std::make_shared<ErrorSlot>();
  auto closeSlot = std::make_shared<ErrorSlot>();

  const std::shared_ptr<StopToken> &stop = [stopToken cpp];

  ComposeRunner::FrameSink sink =
      buildSink(muxer, outputPath, width_i, height_i, openSlot, frameSlot,
                closeSlot, stop);

  RNVPProgressBlock progressCopy = [progress copy];
  std::optional<ProgressEmitter> emitter;
  if (progressCopy != nil) {
    // Open-ended renders stay on std::nullopt nbFrames until the stop token
    // signals finish — the ComposeRunner itself calls updateNbFrames() after
    // the loop exits so the final tick carries a definite ETA=0.
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
        std::optional<double>{});
  }

  ComposeRunner::OpenResult result;
  std::string runError;
  const bool ok = ComposeRunner::runOpen(
      spec, source, sink, *stop, result, runError,
      emitter.has_value() ? &emitter.value() : nullptr);
  if (!ok) {
    populateErrorFromSlots(error, openSlot, frameSlot, closeSlot, runError);
    return NO;
  }

  if (framesWritten != NULL) *framesWritten = result.framesWritten;
  if (aborted != NULL) *aborted = result.aborted ? YES : NO;

  if (result.aborted) {
    // Abort discards the output — a half-finalised MP4 is never useful. The
    // muxer's close was intentionally skipped by ComposeRunner::runOpen, so
    // just remove any partial file AVAssetWriter may have left on disk.
    [fm removeItemAtPath:outputPath error:NULL];
  }

  return YES;
}

@end
