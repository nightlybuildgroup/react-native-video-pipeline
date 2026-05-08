///
/// Transcoder.h
///
/// Obj-C entry point for the iOS transcode path (T033). AVAssetReader with a
/// decompressed BGRA output feeds each source frame through a Core Image
/// pipeline that applies the source's preferredTransform plus any caller-
/// supplied rotate/flip/crop, and scales the result to the encoder target
/// size. The scaled pixel buffer is handed to an AVAssetWriter configured
/// for H.264 or HEVC at the caller-chosen bitrate.
///
/// Compared to the remux paths (@c RNVPRemuxer): every frame is decoded and
/// re-encoded. The price is real — Instruments shows the CI render + encode
/// loop dominating CPU on the macOS host — but it is the only way to change
/// resolution, codec, bitrate, or pixel geometry. Zero JSI calls per frame:
/// the loop is pure Obj-C++ / Core Image / AVFoundation.
///
/// Audio: when the source has an audio track it is passed through compressed
/// (byte-for-byte identical to the source) on a second writer input, mirror-
/// ing the remux paths. No silent-audio authoring — that's the synthesize
/// path's concern, not the transcode path's.
///
/// Frame-mapping semantics: one decoded source sample produces one output
/// sample, retimed to PTS `outputIndex / target.fps`. See
/// `engine/Transcoder.hpp` for the rationale.
///
/// Invoked from @c HybridVideoPipeline::render() in VideoPipeline.mm. Also
/// callable directly from XCTest — tests drive the full AVFoundation chain
/// without needing a JS runtime or the Nitro boundary.
///

#pragma once

#import <Foundation/Foundation.h>

@class RNVPImageOverlay;
@class RNVPTextOverlay;
@class RNVPStampMetadata;
@class RNVPStopToken;

NS_ASSUME_NONNULL_BEGIN

/// See @c SynthesizeRunner.h — same block type, duplicated here so the
/// transcoder header stays self-contained (importing SynthesizeRunner.h
/// just for a typedef would force AVMuxer into callers that don't need it).
typedef void (^RNVPTranscoderProgressBlock)(double framesCompleted,
                                            BOOL nbFramesValid,
                                            double nbFrames, double elapsedMs,
                                            BOOL etaMsValid,
                                            double estimatedRemainingMs);

extern NSErrorDomain const RNVPTranscoderErrorDomain;

typedef NS_ERROR_ENUM(RNVPTranscoderErrorDomain, RNVPTranscoderErrorCode){
    RNVPTranscoderErrorCodeInvalidSpec = 1,
    RNVPTranscoderErrorCodeSourceCorrupted = 2,
    RNVPTranscoderErrorCodeWriterFailed = 3,
    RNVPTranscoderErrorCodeNotFound = 4,
    RNVPTranscoderErrorCodeEncoderFailure = 5,
    RNVPTranscoderErrorCodeCancelled = 6,
};

/// Mirrors the nitrogen-generated @c VideoCodec enum ordinals.
typedef NS_ENUM(NSInteger, RNVPTranscodeCodec) {
  RNVPTranscodeCodecH264 = 0,
  RNVPTranscodeCodecHEVC = 1,
};

/// Immutable snapshot of the encoder target + transform the driver consumes.
/// Every field has a "no change" sentinel so callers can build incremental
/// targets without branching at the call site:
///   - @c bitrate == 0        → driver picks a per-resolution default.
///   - @c rotate  == -1       → preserve source rotation only.
///   - @c cropWidth <= 0      → no crop.
@interface RNVPTranscodeTarget : NSObject
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;
@property(nonatomic, readonly) double fps;
@property(nonatomic, readonly) RNVPTranscodeCodec codec;
@property(nonatomic, readonly) NSInteger bitrate;
@property(nonatomic, readonly) NSInteger rotate;
@property(nonatomic, readonly) BOOL flipH;
@property(nonatomic, readonly) BOOL flipV;
@property(nonatomic, readonly) double cropX;
@property(nonatomic, readonly) double cropY;
@property(nonatomic, readonly) double cropWidth;
@property(nonatomic, readonly) double cropHeight;

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
                   cropHeight:(double)cropHeight NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface RNVPTranscoder : NSObject

/// Transcode @p sourceURL to @p outputURL according to @p target. Blocks the
/// caller until the writer finalises. Returns @c YES on success; on failure
/// populates @p error with an @c RNVPTranscoderErrorDomain error and deletes
/// any partial output file.
///
/// @p overlays, when non-empty, pre-rasterize a list of overlays via
/// @c RNVPOverlayRenderer at open time and composite the currently-active
/// ones onto each decoded frame right before the encoder accepts it. Each
/// array element may be an @c RNVPImageOverlay (T034) or an
/// @c RNVPTextOverlay (T035); the renderer handles each kind at init time
/// and stores a ready-to-composite CIImage either way. @c nil / empty
/// arrays behave identically to the old overlay-less transcode.
///
/// @p metadata, when non-nil, replaces the writer's container-level metadata
/// bag with the merge of the source's existing metadata and this stamp (same
/// semantics as @c RNVPRemuxer +remuxStampFromURL:toURL:metadata: on the
/// remux path). @c nil forwards @c asset.metadata verbatim — used by the
/// overlay-only transcode path in T034/T035 and by every pre-T036 caller.
/// @p stop, when non-nil, is polled inside the encode loop and the
/// ready-wait spin. On abort the writer is cancelled, any partial output
/// file is deleted, and the method returns @c NO with
/// @c RNVPTranscoderErrorCodeCancelled in @p error. Matches the 500ms
/// cancellation budget from @c the cancellation contract — poll cadence is per-frame
/// (up to ~33ms at 30fps) plus the 1ms sleep inside the ready-wait spin.
+ (BOOL)transcodeFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                  target:(RNVPTranscodeTarget *)target
                overlays:(nullable NSArray *)overlays
                metadata:(nullable RNVPStampMetadata *)metadata
                    stop:(nullable RNVPStopToken *)stop
                progress:(nullable RNVPTranscoderProgressBlock)progress
                   error:(NSError *_Nullable __autoreleasing *)error;

@end

NS_ASSUME_NONNULL_END
