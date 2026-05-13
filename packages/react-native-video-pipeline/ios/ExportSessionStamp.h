///
/// ExportSessionStamp.h
///
/// AVAssetExportSession-based driver for the @c Video.stamp watermark path.
/// Replaces the AVAssetReader+AVAssetWriter pump in @c Transcoder.mm for the
/// static-overlay case: an iPhone slo-mo HEVC source (1080p @ 240fps, ~48
/// Mbps) wedges the polling pump on real hardware because the encoder's
/// @c readyForMoreMediaData flag never recovers under the bitrate/fps the
/// stamp router was copying verbatim from the source. AVFoundation's own
/// high-level export pipeline does not have this problem — it owns the
/// encoder pacing, GOP placement, bitrate selection, and audio passthrough.
///
/// The legacy @c VideoTools.exportVideo Swift module in unbogify uses the
/// same API (AVAssetExportSession + AVMutableVideoComposition +
/// AVVideoCompositionCoreAnimationTool); this driver matches its shape so the
/// rendered output is visually equivalent to the pre-pipeline export.
///
/// Scope:
///   - static image and text overlays (the @c RNVPImageOverlay /
///     @c RNVPTextOverlay variants the public @c Video.stamp accepts);
///   - metadata stamping merged via the same
///     @c RNVPStampMetadata (MergeWriting) category the remux path uses;
///   - audio passthrough (AVFoundation handles it via the composition);
///   - container metadata round-trip (preserved when this driver does not
///     overwrite it).
///
/// Out of scope (kept on the old transcode path for now):
///   - per-frame programmatic drawing (the @c Video.compose worklet case) —
///     wired in a follow-up via a custom @c AVVideoCompositing class.
///   - resize / flip / rotate transforms — the stamp router never invokes
///     those; the @c Video.render / @c Video.flip routers will move onto an
///     export-session path in follow-up work.
///

#pragma once

#import <Foundation/Foundation.h>

@class RNVPStampMetadata;

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const RNVPExportSessionStampErrorDomain;

typedef NS_ERROR_ENUM(RNVPExportSessionStampErrorDomain,
                      RNVPExportSessionStampErrorCode){
    RNVPExportSessionStampErrorCodeInvalidSpec = 1,
    RNVPExportSessionStampErrorCodeSourceCorrupted = 2,
    RNVPExportSessionStampErrorCodeExportFailed = 3,
    RNVPExportSessionStampErrorCodeImageLoadFailed = 4,
};

@interface RNVPExportSessionStamp : NSObject

/// Stamp @p sourceURL with @p overlays and @p metadata, writing the result to
/// @p outputURL. Blocks the caller until the export session reports
/// @c AVAssetExportSessionStatusCompleted (success → returns @c YES) or
/// @c …Failed/@c …Cancelled (failure → populates @p error and deletes any
/// partial output file).
///
/// @p overlays is an array of @c RNVPImageOverlay and/or @c RNVPTextOverlay.
/// An empty array is allowed (effective behavior matches a pure metadata
/// stamp via the remux path, but the stamp router only calls this driver
/// when at least one overlay is present).
///
/// @p metadata is the same @c RNVPStampMetadata the remux path takes;
/// @c nil means "preserve the source's container metadata verbatim."
+ (BOOL)stampFromURL:(NSURL *)sourceURL
               toURL:(NSURL *)outputURL
            overlays:(NSArray *)overlays
            metadata:(nullable RNVPStampMetadata *)metadata
               error:(NSError *_Nullable __autoreleasing *)error;

@end

NS_ASSUME_NONNULL_END
