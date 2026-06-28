///
/// Remuxer.h
///
/// Obj-C entry point for the iOS passthrough remux paths. AVAssetReader
/// (compressed passthrough) → AVAssetWriter (compressed passthrough); every
/// entry point shares reader/writer plumbing and differs only in what the
/// writer records as the output video track's @c preferredTransform and
/// time range.
///
///   - @c remuxTrim… — T027. Copies samples inside a [startSec, startSec+
///     durationSec) window; transform is carried through verbatim.
///   - @c remuxFlip… — T028. Copies every sample verbatim, but
///     post-multiplies a horizontal or vertical flip onto the source's
///     @c preferredTransform so the resulting video plays back mirrored
///     without any pixel re-encode.
///   - @c remuxConcat… — T029. Copies the compressed sample stream from N
///     clips in spec order, rebasing each sample's PTS onto a contiguous
///     output timeline. v0.1 scope: same codec/resolution/fps, identical
///     preferred transform, no per-clip transforms, no gaps/overlaps.
///   - @c remuxStamp… — T032. Copies every sample verbatim (video + audio)
///     and overwrites the output container's metadata bag with the supplied
///     @c RNVPStampMetadata. Used by the metadata-only @c Video.stamp route;
///     watermark stamping lands on the transcode path in T036.
///
/// All methods preserve codec, bit rate, resolution, HDR flag, and
/// container-level metadata. Audio passthrough is supported by @c trim and
/// @c flip; @c concat writes video-only in v0.1 (the transcode path in later
/// tasks authors silent audio for multi-clip timelines).
///
/// Invoked by @c HybridVideoPipeline::trim() / @c ::flip() / @c ::render()
/// in VideoPipeline.mm. Also callable directly from XCTest — tests drive the
/// full AVFoundation chain without needing a JS runtime or the Nitro
/// boundary.
///

#pragma once

#import "RNVPAudio.h"

#import <Foundation/Foundation.h>

@class RNVPStopToken;

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const RNVPRemuxerErrorDomain;

typedef NS_ERROR_ENUM(RNVPRemuxerErrorDomain, RNVPRemuxerErrorCode){
    RNVPRemuxerErrorCodeInvalidSpec = 1,
    RNVPRemuxerErrorCodeSourceCorrupted = 2,
    RNVPRemuxerErrorCodeWriterFailed = 3,
    RNVPRemuxerErrorCodeNotFound = 4,
    RNVPRemuxerErrorCodeCancelled = 5,
};

/// Mirrors the nitrogen-generated @c FlipAxis enum (horizontal=0, vertical=1)
/// so the @c HybridVideoPipeline adapter can map without a lookup table.
typedef NS_ENUM(NSInteger, RNVPFlipAxis) {
  RNVPFlipAxisHorizontal = 0,
  RNVPFlipAxisVertical = 1,
};

@interface RNVPRemuxer : NSObject

/// Trim-by-remux: copy compressed video (and audio, when present) from
/// @p sourceURL to @p outputURL, keeping only samples inside the half-open
/// interval [startSec, startSec+durationSec). Blocks the caller until the
/// writer has finished. Preserves:
///   - video codec + bit rate + resolution + HDR transfer characteristic
///     (passthrough — samples are byte-for-byte identical to the source),
///   - rotation (copied from @c AVAssetTrack.preferredTransform onto the
///     writer's video input — no pixels are modified),
///   - container-level metadata (creation date, location, software, …) —
///     @c AVURLAsset.metadata is forwarded to @c AVAssetWriter.metadata.
///
/// Returns @c YES on success. On failure populates @p error with an
/// @c RNVPRemuxerErrorDomain error; the output file is deleted so callers
/// never observe a partial MP4/MOV.
+ (BOOL)remuxTrimFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                startSec:(double)startSec
             durationSec:(double)durationSec
                   error:(NSError *_Nullable __autoreleasing *)error;

/// As @c remuxTrimFromURL:toURL:startSec:durationSec:error: but honouring an
/// @c RNVPAudioMode: @c Passthrough keeps the source audio (identical to the
/// shorter selector), @c Mute drops the audio track, @c Replace swaps in
/// @p audioReplacementURL (capped to the trim window).
+ (BOOL)remuxTrimFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                startSec:(double)startSec
             durationSec:(double)durationSec
               audioMode:(RNVPAudioMode)audioMode
     audioReplacementURL:(nullable NSURL *)audioReplacementURL
                   error:(NSError *_Nullable __autoreleasing *)error;

/// Flip-by-remux: copy every compressed sample (video + optional audio)
/// from @p sourceURL to @p outputURL and post-multiply a flip matrix onto
/// the video track's @c preferredTransform so playback is mirrored on the
/// requested axis. No pixel bytes are modified — the sample stream is
/// byte-for-byte identical to the source; the only on-disk difference is
/// the container-level transform matrix.
///
/// The flip is expressed in the source's natural-pixel coordinates:
///   horizontal → x' = naturalWidth  − x
///   vertical   → y' = naturalHeight − y
/// and composed on top of the source's existing preferredTransform via
/// @c CGAffineTransformConcat, so rotation-then-flip order matches what a
/// user sees at playback on a source with identity preferredTransform
/// (which is the AVMuxer-authored case covered by the T024 fixtures).
///
/// Container support: MP4/MOV always support @c preferredTransform; for any
/// other source container this method rejects with
/// @c RNVPRemuxerErrorCodeInvalidSpec pointing at the T033 transcode fallback
/// (which is not wired yet).
///
/// Returns @c YES on success; on failure populates @p error and deletes any
/// partial output file.
+ (BOOL)remuxFlipFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                    axis:(RNVPFlipAxis)axis
                   error:(NSError *_Nullable __autoreleasing *)error;

/// As @c remuxFlipFromURL:toURL:axis:error: but honouring an
/// @c RNVPAudioMode (see @c remuxTrimFromURL: variant).
+ (BOOL)remuxFlipFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                    axis:(RNVPFlipAxis)axis
               audioMode:(RNVPAudioMode)audioMode
     audioReplacementURL:(nullable NSURL *)audioReplacementURL
                   error:(NSError *_Nullable __autoreleasing *)error;

/// Trim + rotate/flip in one lossless remux pass. Copies the compressed
/// sample stream for the half-open window [startSec, startSec+durationSec)
/// (a @p durationSec <= 0 means "to the end of the source") into @p outputURL
/// and writes a @c preferredTransform composed from the source's own transform
/// plus the requested rotation (degrees, one of {0,90,180,270}; pass a
/// negative value for "no rotation") and horizontal/vertical flips. No pixels
/// are re-encoded — this is the fast path the render router picks for any
/// rotation/flip-only single-clip spec (with or without a trim window). Crop,
/// resolution/codec/bitrate changes, and overlays are NOT expressible here and
/// route to @c RNVPTranscoder instead.
///
/// The transform is composed in the source's natural-pixel frame as
/// `preferred → rotate → flip` (matching the transcode pipeline's visual
/// order) and re-normalized so the output's displayed frame sits at a
/// non-negative origin. Audio, codec, bit rate, resolution, HDR flag, and
/// container metadata are all preserved (passthrough).
///
/// Returns @c YES on success; on failure populates @p error and deletes any
/// partial output file.
+ (BOOL)remuxTransformFromURL:(NSURL *)sourceURL
                        toURL:(NSURL *)outputURL
                     startSec:(double)startSec
                  durationSec:(double)durationSec
                       rotate:(NSInteger)rotate
                        flipH:(BOOL)flipH
                        flipV:(BOOL)flipV
                        error:(NSError *_Nullable __autoreleasing *)error;

/// As @c remuxTransformFromURL:…:error: but honouring an @c RNVPAudioMode
/// (see @c remuxTrimFromURL: variant). @c Replace is capped to the trim window.
+ (BOOL)remuxTransformFromURL:(NSURL *)sourceURL
                        toURL:(NSURL *)outputURL
                     startSec:(double)startSec
                  durationSec:(double)durationSec
                       rotate:(NSInteger)rotate
                        flipH:(BOOL)flipH
                        flipV:(BOOL)flipV
                    audioMode:(RNVPAudioMode)audioMode
          audioReplacementURL:(nullable NSURL *)audioReplacementURL
                        error:(NSError *_Nullable __autoreleasing *)error;

@end

/// One clip on a multi-clip concat timeline. Mirrors the numeric fields of
/// the JS-side @c Clip struct; the concat path rejects any non-empty
/// @c ClipTransform so per-clip rotation/flip/crop does not appear here.
@interface RNVPRemuxerConcatSource : NSObject
@property(nonatomic, readonly) NSURL *sourceURL;
@property(nonatomic, readonly) double sourceStart;
@property(nonatomic, readonly) double sourceDuration;
@property(nonatomic, readonly) double outputStart;

- (instancetype)initWithSourceURL:(NSURL *)sourceURL
                      sourceStart:(double)sourceStart
                   sourceDuration:(double)sourceDuration
                      outputStart:(double)outputStart NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface RNVPRemuxer (Concat)

/// Concat-by-remux: copy compressed video samples from @p sources in spec
/// order into @p outputURL, rebasing each sample's PTS onto a contiguous
/// output timeline so playback sees a single continuous video.
///
/// v0.1 scope:
///   - every source must carry the same video codec, natural size, and
///     @c preferredTransform as the first; mismatches reject with
///     @c RNVPRemuxerErrorCodeInvalidSpec pointing at the transcode
///     fallback (not wired yet).
///   - the timeline must be contiguous and start at 0 — gaps and overlaps
///     are rejected with the same @c InvalidSpec rationale.
///   - audio is dropped. Concat's silent-audio authoring lands on the
///     transcode path in a later task.
///   - container-level metadata is forwarded from the first source.
///
/// Returns @c YES on success; on failure populates @p error and deletes any
/// partial output file.
+ (BOOL)remuxConcatSources:(NSArray<RNVPRemuxerConcatSource *> *)sources
                     toURL:(NSURL *)outputURL
                      stop:(nullable RNVPStopToken *)stop
                     error:(NSError *_Nullable __autoreleasing *)error;

@end

/// Container-level metadata bag for @c +remuxStampFromURL:toURL:metadata:error:.
/// Mirrors the optional fields of @c MetadataSpec in the Nitro spec; each
/// field is independently optional so callers can set only what they want
/// to write. An empty bag (all nil / hasGps=NO / no custom entries) is a
/// legal input and produces a metadata-free output.
@interface RNVPStampMetadata : NSObject
@property(nonatomic, readonly) BOOL hasGps;
@property(nonatomic, readonly) double gpsLatitude;
@property(nonatomic, readonly) double gpsLongitude;
/// Optional altitude (metres above WGS-84). Distinct from @c hasGps —
/// callers may write lat/lon without altitude. Only meaningful when
/// @c hasGps is YES.
@property(nonatomic, readonly) BOOL hasGpsAltitude;
@property(nonatomic, readonly) double gpsAltitude;
@property(nonatomic, readonly, nullable, copy) NSString *software;
@property(nonatomic, readonly, nullable, copy) NSDate *creationDate;
/// Maps to @c MetadataSpec.description; named to avoid colliding with
/// NSObject's @c description selector.
@property(nonatomic, readonly, nullable, copy) NSString *contentDescription;
@property(nonatomic, readonly, nullable, copy)
    NSDictionary<NSString *, NSString *> *custom;

- (instancetype)initWithGps:(BOOL)hasGps
                   latitude:(double)latitude
                  longitude:(double)longitude
             hasGpsAltitude:(BOOL)hasGpsAltitude
                   altitude:(double)altitude
                   software:(nullable NSString *)software
               creationDate:(nullable NSDate *)creationDate
         contentDescription:(nullable NSString *)contentDescription
                     custom:(nullable NSDictionary<NSString *, NSString *> *)custom
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface RNVPRemuxer (Stamp)

/// Stamp-by-remux: copy every compressed sample (video + optional audio)
/// from @p sourceURL to @p outputURL, replacing the container's
/// metadata bag with items built from @p metadata merged on top of the
/// source's existing metadata. Fields that @p metadata sets override
/// matching items from the source; fields it leaves nil are forwarded
/// verbatim (so a narrow stamp does not erase creation date / location
/// already on the source).
///
/// Standard fields (location, software, creationDate, description) are written
/// using the corresponding @c AVMetadataCommonIdentifier* so they round-trip
/// through @c RNVPAVDemuxer. Custom string→string entries are authored under
/// the @c mdta/<key> identifier namespace, with the caller-supplied key
/// passed through verbatim — convention is reverse-DNS
/// (@c "com.acme.shotanalysis") but the library does not validate. Both
/// the iOS demuxer and external tools (exiftool, mediainfo, ffprobe) read
/// these back as @c mdta/<key> = <value> entries.
///
/// @p metadata may be @c nil, in which case this is a pure passthrough
/// remux that copies the source and its metadata through unchanged.
///
/// Returns @c YES on success; on failure populates @p error and deletes any
/// partial output file.
+ (BOOL)remuxStampFromURL:(NSURL *)sourceURL
                    toURL:(NSURL *)outputURL
                 metadata:(nullable RNVPStampMetadata *)metadata
                    error:(NSError *_Nullable __autoreleasing *)error;

/// As @c remuxStampFromURL:toURL:metadata:error: but honouring an
/// @c RNVPAudioMode (see @c remuxTrimFromURL: variant).
+ (BOOL)remuxStampFromURL:(NSURL *)sourceURL
                    toURL:(NSURL *)outputURL
                 metadata:(nullable RNVPStampMetadata *)metadata
                audioMode:(RNVPAudioMode)audioMode
      audioReplacementURL:(nullable NSURL *)audioReplacementURL
                    error:(NSError *_Nullable __autoreleasing *)error;

@end

NS_ASSUME_NONNULL_END
