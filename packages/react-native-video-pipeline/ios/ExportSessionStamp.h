///
/// ExportSessionStamp.h
///
/// AVAssetExportSession-based driver for the @c Video.stamp watermark path
/// when the overlay is static (image / text — not a per-frame worklet).
/// Uses AVFoundation's high-level export pipeline so the encoder, audio
/// passthrough, container metadata, GOP placement, and bitrate selection
/// are owned by the framework rather than the library.
///
/// Scope:
///   - static image and text overlays (the @c RNVPImageOverlay /
///     @c RNVPTextOverlay variants the public @c Video.stamp accepts);
///   - metadata stamping merged via the same
///     @c RNVPStampMetadata (MergeWriting) category the remux path uses;
///   - audio passthrough (AVFoundation handles it via the composition);
///   - container metadata round-trip.
///
/// Out of scope (handled elsewhere in the library):
///   - per-frame programmatic drawing (the @c Video.compose worklet case)
///     stays on the @c RNVPTranscoder read/write pump, which gives the
///     library frame-level control needed to invoke a JS callback per frame.
///   - resize / flip / rotate transforms — the stamp router never invokes
///     those; @c Video.render / @c Video.flip have their own routers.
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
