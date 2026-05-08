///
/// AVDemuxer.h
///
/// Thin Objective-C++ wrapper around AVAssetReader used as the source for the
/// remux paths (trim/flip/concat — T027+) and the probe path (Video.info —
/// T026). T025 scope is narrow: open a file URL, read the source video track's
/// metadata (codec, bit rate, dimensions, fps, rotation, HDR flag, color
/// primaries), and stream compressed sample buffers in PTS order. Audio
/// passthrough lands with the remux tasks; for now this class only tracks
/// whether an audio track exists.
///
/// Sample output is intentionally compressed (`outputSettings:nil`) so the
/// remux path can re-mux the encoded H.264/HEVC bytes without a decode/encode
/// round trip. Decoded sample access is a later concern of the transcode path
/// (T033) and lives in a separate reader configuration.
///
/// Call order:
///   1. -openAtURL:error:        (populates the metadata properties)
///   2. -copyNextVideoSampleBuffer: (N times, returns NULL at EOS)
///   3. -closeWithError:
///
/// After -closeWithError: the instance is spent; create a new demuxer for the
/// next file. Re-entering -openAtURL: on a closed demuxer raises an error.
///

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const RNVPAVDemuxerErrorDomain;

typedef NS_ERROR_ENUM(RNVPAVDemuxerErrorDomain, RNVPAVDemuxerErrorCode){
    RNVPAVDemuxerErrorCodeInvalidState = 1,
    RNVPAVDemuxerErrorCodeNotFound = 2,
    RNVPAVDemuxerErrorCodeNoVideoTrack = 3,
    RNVPAVDemuxerErrorCodeReaderFailed = 4,
};

@interface RNVPAVDemuxer : NSObject

/// Open the source at @c url and load the first video track's metadata.
/// Returns @c NO and populates @c error if the file does not exist, has no
/// video track, or the underlying @c AVAssetReader fails to start.
- (BOOL)openAtURL:(NSURL *)url
            error:(NSError *_Nullable __autoreleasing *)error;

/// Returns the next compressed video sample buffer in PTS order, or @c NULL
/// at end-of-stream. The returned buffer is CF-retained — the caller owns it
/// and must @c CFRelease when done. Populates @c error on a reader failure
/// (distinct from EOS, which sets @c error to @c nil).
- (CMSampleBufferRef _Nullable)copyNextVideoSampleBuffer:
    (NSError *_Nullable __autoreleasing *)error CF_RETURNS_RETAINED;

/// Tear down the underlying reader. Safe to call exactly once after a
/// successful open. Subsequent calls return an InvalidState error.
- (BOOL)closeWithError:(NSError *_Nullable __autoreleasing *)error;

/// Canonical codec label: @c "h264" for avc1/avc3, @c "hevc" for hvc1/hev1,
/// otherwise the FourCC of the video track's format description as an ASCII
/// string. Only valid after a successful open.
@property(nonatomic, readonly, nullable) NSString *codec;

/// Container label derived from the URL extension: @c "mp4" or @c "mov" for
/// the formats this library writes; lower-cased extension otherwise.
@property(nonatomic, readonly, nullable) NSString *container;

/// Bits per second, as reported by AVAssetTrack.estimatedDataRate. Rounded to
/// the nearest integer. 0 if AVFoundation could not estimate.
@property(nonatomic, readonly) NSInteger bitRate;

/// Pixel dimensions of the video track's natural size. AVFoundation rounds
/// fractional natural sizes to the nearest int; this property forwards that.
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;

/// AVAssetTrack.nominalFrameRate (float). For an integer-fps file authored by
/// RNVPAVMuxer this matches what was passed to -openAtPath:width:height:fps:
/// within ±0.5.
@property(nonatomic, readonly) double fps;

/// Duration of the asset in seconds.
@property(nonatomic, readonly) double durationSec;

/// Rotation derived from the video track's preferredTransform: 0/90/180/270.
/// Source rotation is reported here, never applied — consumers decide whether
/// to bake it into the output (T028 Video.flip) or pass it through.
@property(nonatomic, readonly) NSInteger rotation;

/// @c YES when the video format description carries an HDR transfer function
/// (HLG or PQ). Color primaries alone (e.g. BT.2020 with BT.709 transfer) do
/// not flip this flag — HDR specifically means the *transfer characteristic*
/// is HLG/PQ, which is what downstream encoders care about.
@property(nonatomic, readonly) BOOL isHDR;

/// @c YES if the source has at least one audio track.
@property(nonatomic, readonly) BOOL hasAudio;

/// Color primaries string from the video format description, e.g.
/// @c "ITU_R_709_2", @c "ITU_R_2020". @c nil when the format description does
/// not carry the extension (rare for files this library writes; common for
/// some hand-authored MP4s).
@property(nonatomic, readonly, nullable) NSString *colorPrimaries;

/// Container-level creation date pulled from the source's common metadata
/// (@c AVMetadataCommonKeyCreationDate). @c nil when the source carries no
/// creation-date item or when the item cannot be coerced into an @c NSDate.
@property(nonatomic, readonly, nullable) NSDate *creationDate;

/// @c YES when the source exposes a parseable ISO 6709 location item under
/// @c AVMetadataCommonKeyLocation. Fails closed: malformed location strings
/// leave this @c NO rather than returning garbage coordinates.
@property(nonatomic, readonly) BOOL hasLocation;

/// WGS-84 decimal degrees. Only meaningful when @c hasLocation is @c YES.
@property(nonatomic, readonly) double locationLatitude;
@property(nonatomic, readonly) double locationLongitude;

/// @c YES when the source's ISO 6709 location item carried a third token
/// (altitude in metres). Distinct from @c hasLocation because lat+lon can
/// be present without altitude. @c locationAltitude is meaningful only
/// when this is @c YES.
@property(nonatomic, readonly) BOOL hasLocationAltitude;
@property(nonatomic, readonly) double locationAltitude;

/// Container-level description from @c AVMetadataCommonKeyDescription.
/// @c nil when absent. Excluded from @c customMetadata to mirror the
/// special-cased treatment of @c creationDate / @c hasLocation — symmetric
/// with the stamp side which writes description to the same common key.
@property(nonatomic, readonly, nullable, copy) NSString *contentDescription;

/// Common-metadata items that don't have a dedicated property of their own,
/// keyed by @c AVMetadataCommonKey* (e.g. @c "software"). @c nil when the
/// source carries none. Values are coerced to @c NSString; binary or
/// non-stringifiable metadata items are skipped.
@property(nonatomic, readonly, nullable)
    NSDictionary<NSString *, NSString *> *customMetadata;

@end

NS_ASSUME_NONNULL_END
