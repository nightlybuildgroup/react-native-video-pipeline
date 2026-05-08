///
/// SynthesizeRunner.h
///
/// Obj-C entry point that wires `ComposeRunner` (cpp/compose/ComposeRunner.hpp)
/// into AVMuxer + WorkletFrameBridge for the iOS synthesize paths (docs/api.md).
/// The runner:
///   1. Allocates a `RNVPAVMuxer` opened at the requested output path.
///   2. Registers a FrameSource that produces a deterministic RGBA8888 test
///      pattern for each `frameIndex`. This is the v0.1 placeholder for the
///      eventual Reanimated/Skia worklet pump — the contract (`fill an RGBA
///      buffer given a frame index`) is exactly what a real worklet bridge
///      will hand over, so future tasks can swap the source in-place.
///   3. Registers a FrameSink that pushes each RGBA buffer through
///      `RNVPWorkletFrameBridge` to get an `IOSurface`-backed `CVPixelBuffer`
///      and feeds it to the muxer at `frameIndex / fps`.
///
/// Two modes exposed:
///   - `runFixedWithOutputPath:` — US11; writes exactly `round(fps*seconds)`
///     frames, closes.
///   - `runOpenWithOutputPath:` — US12; writes frames until the
///     `RNVPStopToken` receives `requestFinish` / `requestAbort`, or the
///     source signals `ctx.finish()` on a given frame, or the optional
///     `maxSeconds` safety cap fires. On abort the partial file is deleted.
///
/// Invoked by `HybridVideoPipeline::render()` for null-input specs. Also
/// callable directly from XCTest — tests exercise the full AVMuxer chain
/// without needing a JS runtime or a Nitro `VideoSpec`.
///

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const RNVPSynthesizeRunnerErrorDomain;

typedef NS_ERROR_ENUM(RNVPSynthesizeRunnerErrorDomain, RNVPSynthesizeRunnerErrorCode) {
  RNVPSynthesizeRunnerErrorCodeInvalidSpec = 1,
  RNVPSynthesizeRunnerErrorCodeOpenFailed = 2,
  RNVPSynthesizeRunnerErrorCodeFrameFailed = 3,
  RNVPSynthesizeRunnerErrorCodeCloseFailed = 4,
};

/// Obj-C wrapper around `margelo::nitro::videopipeline::StopToken` so pure-`.m`
/// test targets can drive the open-ended stop signal without touching C++.
/// Thread-safe; `requestFinish` / `requestAbort` may be called from any queue.
@interface RNVPStopToken : NSObject
- (instancetype)init;
- (void)requestFinish;
- (void)requestAbort;
/// True once `requestFinish` has been called (regardless of subsequent aborts).
@property(nonatomic, readonly) BOOL finishRequested;
/// True once `requestAbort` has been called.
@property(nonatomic, readonly) BOOL abortRequested;
@end

/// Block passed to the synthesize / transcode entry points so T037's progress
/// callback can reach XCTests + the @c HybridVideoPipeline wiring without
/// dragging the nitrogen-generated @c Progress struct into every translation
/// unit. The four scalars mirror the @c Progress fields 1:1; @c nbFramesValid
/// and @c etaMsValid encode the two @c std::optional fields. Invoked on the
/// runner's thread — the Nitro @c std::function wrapper marshals the call
/// back to the JS thread on its own side.
typedef void (^RNVPProgressBlock)(double framesCompleted, BOOL nbFramesValid,
                                  double nbFrames, double elapsedMs,
                                  BOOL etaMsValid, double estimatedRemainingMs);

@interface RNVPSynthesizeRunner : NSObject

/// Runs the fixed-duration synthesize loop end-to-end: opens a muxer at
/// @p outputPath, writes `round(fps * seconds)` frames of the placeholder
/// pattern, and closes. Blocks the caller until the muxer has finished.
/// Returns @c YES on success. On failure returns @c NO with @p error set to
/// an @c RNVPSynthesizeRunnerErrorDomain error; the output file may have
/// been partially created and should be treated as garbage.
///
/// When @p progress is non-nil the runner coalesces ticks to ≥10 Hz
/// natively (per the cancellation contract) before invoking the block. The block will
/// fire at least twice — an initial @c framesCompleted=0 tick and a final
/// @c framesCompleted=round(fps*seconds) tick — so UIs never have to guess
/// at the start/end of the bar.
///
/// When @p stopToken is non-nil the runner polls its abort flag before each
/// frame. On abort the output file is deleted, @p aborted (if non-NULL) is
/// set to @c YES, and the method still returns @c YES — abort is a
/// user-driven success path, not an engine error. @c finishRequested is
/// ignored on the fixed path per @c VideoRenderController's policy.
+ (BOOL)runFixedWithOutputPath:(NSString*)outputPath
                         width:(NSInteger)width
                        height:(NSInteger)height
                           fps:(double)fps
                       seconds:(double)seconds
                     stopToken:(nullable RNVPStopToken*)stopToken
                      progress:(nullable RNVPProgressBlock)progress
                       aborted:(BOOL* _Nullable)aborted
                         error:(NSError* __autoreleasing _Nullable* _Nullable)error;

/// Runs the open-ended synthesize loop. Blocks the caller. Termination paths
/// (any one of them stops the loop):
///   - @p stopToken receives @c requestFinish — last frame is appended, file
///     is finalised, @c aborted out-param is set to @c NO.
///   - @p stopToken receives @c requestAbort — loop exits immediately, file
///     is deleted (partial MP4 is never useful), @c aborted is set to @c YES,
///     method still returns @c YES (abort is a user-driven success path, not
///     an engine error).
///   - @p finishOnFrame is non-negative and the source has produced that
///     frame — simulates `ctx.finish()` from a worklet. File is finalised,
///     @c aborted is @c NO. Pass @c -1 to disable this hook (production path
///     — no `ctx.finish()` plumbing until T041).
///   - @p maxSeconds is positive and the next PTS would reach or exceed it.
///     File is finalised, @c aborted is @c NO.
///
/// @p framesWritten and @p aborted may be @c NULL if the caller doesn't care.
+ (BOOL)runOpenWithOutputPath:(NSString*)outputPath
                        width:(NSInteger)width
                       height:(NSInteger)height
                          fps:(double)fps
                   maxSeconds:(double)maxSeconds
                    stopToken:(RNVPStopToken*)stopToken
                finishOnFrame:(NSInteger)finishOnFrame
                     progress:(nullable RNVPProgressBlock)progress
                framesWritten:(NSInteger* _Nullable)framesWritten
                      aborted:(BOOL* _Nullable)aborted
                         error:(NSError* __autoreleasing _Nullable* _Nullable)error;

@end

NS_ASSUME_NONNULL_END
