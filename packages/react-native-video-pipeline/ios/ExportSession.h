///
/// ExportSession.h
///
/// Unified iOS driver for "source video → per-frame transform → output video"
/// operations. Wraps the canonical AVFoundation pattern:
///
///   AVURLAsset
///     → AVMutableComposition (insertTimeRange: ofTrack:)
///     → AVMutableVideoComposition (renderSize, frameDuration,
///                                  customVideoCompositorClass)
///     → AVAssetExportSession (preset, outputURL)
///
/// AVFoundation owns the encoder, audio passthrough, GOP placement, bitrate
/// selection, and the multi-threaded pixel-buffer pool. The library only
/// supplies the per-frame work via a composer block.
///
/// Used by:
///   - @c Video.stamp (watermark — static image/text overlays)
///   - @c Video.compose (worklet — per-frame JS draw)
///   - @c Video.render / @c Video.flip / non-passthrough @c Video.trim
///     (programmatic transforms — flip, rotate, resize, crop)
///
/// NOT used by:
///   - @c Video.synthesize and the null-input @c Video.compose case — those
///     have no source asset for AVAssetExportSession to consume; they use
///     the bare @c RNVPAVMuxer writer pattern instead.
///   - Pure passthrough remux paths (@c Video.trim no-flip,
///     metadata-only @c Video.stamp) — those stay on @c RNVPRemuxer for
///     true byte-for-byte sample passthrough.
///

#pragma once

#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

@class RNVPStampMetadata;
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
/// @p source directly.
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

@interface RNVPExportSession : NSObject

/// Export @p sourceURL through @p composer to @p outputURL.
///
/// @param sourceURL  File URL of the source video. Must exist and have at
///                   least one video track.
/// @param outputURL  File URL the result will be written to. Pre-existing
///                   files are removed before the export starts.
/// @param composer   Per-frame composer block. See @c RNVPExportSessionComposer.
/// @param metadata   Optional stamp metadata. Merged on top of the source's
///                   container metadata via
///                   @c RNVPStampMetadata.mergedWithSourceMetadata:.
/// @param stop       Optional cancellation token. When fired, the export is
///                   aborted and any partial output file is deleted.
/// @param progress   Optional progress callback. Invoked once per output
///                   frame on the compositor's rendering queue.
/// @param error      Out-error.
///
/// Returns @c YES on a successful export. On failure, @p error is populated
/// with an @c RNVPExportSessionErrorDomain error and any partial output file
/// is deleted.
+ (BOOL)exportFromURL:(NSURL *)sourceURL
                toURL:(NSURL *)outputURL
              composer:(RNVPExportSessionComposer)composer
              metadata:(nullable RNVPStampMetadata *)metadata
                  stop:(nullable RNVPStopToken *)stop
              progress:(nullable RNVPExportSessionProgress)progress
                 error:(NSError *_Nullable __autoreleasing *)error;

@end

NS_ASSUME_NONNULL_END
