///
/// ExportSession.h
///
/// Unified iOS driver for AVAssetExportSession-backed operations. One request
/// struct (@c RNVPExportRequest), one entry point (@c +runRequest:error:).
/// The driver internally picks between the two backend shapes AVFoundation
/// gives us based on what's in the request:
///
///   - Passthrough (no composer): @c AVAssetExportSession with
///     @c AVAssetExportPresetPassthrough. Copies compressed samples verbatim;
///     AVFoundation owns muxer pacing, edit-list rebasing, audio passthrough,
///     transform preservation. Used by @c Video.trim (no transform) and the
///     metadata-only legs of @c Video.stamp / @c Video.flip.
///
///   - Composition (with composer): @c AVMutableComposition →
///     @c AVMutableVideoComposition (custom compositor) →
///     @c AVAssetExportSession with @c AVAssetExportPresetHighestQuality.
///     AVFoundation owns the encoder; the library only supplies the
///     per-frame work. Used by @c Video.stamp (watermark) and the per-clip
///     leg of @c Video.compose.
///
/// NOT used by:
///   - @c Video.render / re-encode transcode with explicit bitrate/codec
///     control — those go through @c RNVPTranscoder, which uses
///     @c AVAssetWriter directly because @c AVAssetExportSession presets
///     don't expose @c AVVideoAverageBitRateKey / @c AVVideoCodecKey.
///     Follow-up work could give that driver the same request-style API.
///   - @c Video.synthesize and null-input @c Video.compose — no source asset
///     for AVAssetExportSession to consume; uses @c RNVPAVMuxer directly.
///
/// Composition passthrough (@c initWithComposedAsset:): a third shape that
/// hands a pre-built @c AVAsset (typically an @c AVMutableComposition that
/// already bakes the video track's @c preferredTransform, the trim window,
/// and the clip ordering) straight to the passthrough preset — no @c composer,
/// no re-encode. @c Video.flip, the transform-remux, and multi-clip concat all
/// use this, so they share one driver instead of three hand-rolled
/// @c AVAssetExportSession blocks (and, for flip, the retired manual
/// @c AVAssetReader→AVAssetWriter pump that wedged on real-device slo-mo HEVC).
///

#pragma once

#import "RNVPAudio.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

@class RNVPStopToken;

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const RNVPExportSessionErrorDomain;

typedef NS_ERROR_ENUM(RNVPExportSessionErrorDomain,
                      RNVPExportSessionErrorCode){
    RNVPExportSessionErrorCodeInvalidSpec = 1,
    RNVPExportSessionErrorCodeSourceCorrupted = 2,
    RNVPExportSessionErrorCodeExportFailed = 3,
    RNVPExportSessionErrorCodeCancelled = 4,
    RNVPExportSessionErrorCodeComposerFailed = 5,
};

/// Per-frame composer block. The driver calls this once per output frame on
/// an AVFoundation-owned background queue (not the main thread). The
/// implementation receives the source frame as a @c CIImage that already has
/// the source's @c preferredTransform applied, and returns the composited
/// @c CIImage AVFoundation should emit. To pass the source through unchanged
/// (e.g. when a time-ranged overlay isn't active for this frame), return
/// @p sourceImage directly.
///
/// Synchronicity contract: the block is called synchronously and must return
/// before the next frame is requested. Async work the implementation needs
/// to wait on (e.g. a JS worklet's Promise) must be awaited inside the block.
typedef CIImage *_Nonnull (^RNVPExportSessionComposer)(
    CIImage *sourceImage,
    CMTime presentationTime,
    int32_t frameIndex);

/// Progress callback. Invoked from the compositor's rendering queue, never
/// from the main thread. @p framesCompleted is monotonic, @p nbFrames is the
/// pre-computed total (may be approximate for variable-rate sources).
typedef void (^RNVPExportSessionProgress)(int32_t framesCompleted,
                                           int32_t nbFrames);

/// Immutable request struct consumed by @c RNVPExportSession.+runRequest:error:.
/// Fields are read-only — build with the designated initializer.
///
/// Backend selection follows from the field combination:
///   - @c composer nil  → passthrough preset, no composition built
///   - @c composer set  → composition preset (HighestQuality), composer
///                        invoked per output frame
///
/// @c timeRange is @c kCMTimeRangeInvalid for "use the asset's full range";
/// otherwise the export session window is set verbatim (caller is
/// responsible for clamping to the source's actual duration when in doubt).
@interface RNVPExportRequest : NSObject

/// Exactly one of @c source / @c composedAsset is non-nil. @c source drives the
/// URL-asset path (trim, watermark, compose); @c composedAsset drives the
/// composition-passthrough path (flip, transform-remux, concat).
@property(nonatomic, readonly, nullable) NSURL *source;
@property(nonatomic, readonly, nullable) AVAsset *composedAsset;
@property(nonatomic, readonly) NSURL *output;
@property(nonatomic, readonly) CMTimeRange timeRange;
@property(nonatomic, readonly, nullable)
    NSArray<AVMetadataItem *> *metadata;
@property(nonatomic, readonly, nullable) RNVPExportSessionComposer composer;
@property(nonatomic, readonly, nullable) RNVPStopToken *stop;
@property(nonatomic, readonly, nullable) RNVPExportSessionProgress progress;

/// Audio handling for the @c source path (the driver owns the soundtrack on
/// the passthrough preset and the composer composition). @c Passthrough keeps
/// the source audio; @c Mute drops it; @c Replace swaps in
/// @c audioReplacementURL. Ignored on the @c composedAsset path — there the
/// caller has already baked the audio tracks into the composition.
@property(nonatomic, readonly) RNVPAudioMode audioMode;
/// Non-nil only when @c audioMode is @c Replace.
@property(nonatomic, readonly, nullable) NSURL *audioReplacementURL;

/// Caller-built video composition for the @c composedAsset re-encode shape
/// (multi-clip crossfade overlaps, #18). When non-nil alongside
/// @c composedAsset, the driver re-encodes through the HighestQuality preset
/// with this composition set on the session — the layer instructions'
/// opacity ramps produce the crossfade. Nil on every other path.
@property(nonatomic, readonly, nullable)
    AVVideoComposition *videoComposition;
/// Optional audio crossfade for the @c videoComposition shape. The caller
/// builds the volume ramps over the overlap windows; the driver just hands it
/// to the session. Nil leaves the composition's audio tracks at full volume.
@property(nonatomic, readonly, nullable) AVAudioMix *audioMix;

- (instancetype)initWithSource:(NSURL *)source
                        output:(NSURL *)output
                     timeRange:(CMTimeRange)timeRange
                      metadata:(nullable NSArray<AVMetadataItem *> *)metadata
                      composer:(nullable RNVPExportSessionComposer)composer
                     audioMode:(RNVPAudioMode)audioMode
           audioReplacementURL:(nullable NSURL *)audioReplacementURL
                          stop:(nullable RNVPStopToken *)stop
                      progress:(nullable RNVPExportSessionProgress)progress
    NS_DESIGNATED_INITIALIZER;

/// Composition-passthrough request. The composition is expected to already
/// encode the full edit (windowing, ordering, overridden @c preferredTransform),
/// so there is no @c timeRange or @c composer — the export copies compressed
/// samples verbatim and writes the composition track's transform.
- (instancetype)initWithComposedAsset:(AVAsset *)composedAsset
                               output:(NSURL *)output
                             metadata:(nullable NSArray<AVMetadataItem *> *)metadata
                                 stop:(nullable RNVPStopToken *)stop
                             progress:(nullable RNVPExportSessionProgress)progress;

/// Composition **re-encode** request (#18 crossfade overlaps). The composition
/// carries the overlapping clip tracks; @p videoComposition supplies the
/// per-region layer instructions (opacity ramps) that blend them, and the
/// optional @p audioMix supplies the matching volume ramps. Unlike
/// @c initWithComposedAsset: this re-encodes (HighestQuality preset) because a
/// blended frame can't be copied through verbatim.
- (instancetype)initWithComposedAsset:(AVAsset *)composedAsset
                     videoComposition:(AVVideoComposition *)videoComposition
                             audioMix:(nullable AVAudioMix *)audioMix
                               output:(NSURL *)output
                             metadata:(nullable NSArray<AVMetadataItem *> *)metadata
                                 stop:(nullable RNVPStopToken *)stop
                             progress:(nullable RNVPExportSessionProgress)progress;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface RNVPExportSession : NSObject

/// Run @p request synchronously. Returns @c YES on success; on failure
/// populates @p error with an @c RNVPExportSessionErrorDomain error and
/// deletes any partial output file. Blocks the caller until the export
/// session reports @c …Completed (success) or @c …Failed / @c …Cancelled
/// (failure).
+ (BOOL)runRequest:(RNVPExportRequest *)request
             error:(NSError *_Nullable __autoreleasing *)error;

@end

NS_ASSUME_NONNULL_END
