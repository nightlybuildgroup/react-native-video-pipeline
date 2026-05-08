///
/// AVMuxer.h
///
/// Thin Objective-C++ wrapper around AVAssetWriter used as the sink for every
/// iOS render path (synthesize, transcode, compose). T018 scope is deliberately
/// small: the muxer holds an H.264 video input and a silent AAC audio input,
/// and exposes only open/append/close. No overlays, no reader, no routing.
///
/// Call order:
///   1. -openAtPath:width:height:fps:error:
///   2. -appendPixelBuffer:presentationTime:error: (N times, monotonic PTS)
///   3. -closeWithError:
///
/// After -closeWithError: the instance is spent; create a new muxer for the
/// next file. Re-entering -openAtPath: on a closed muxer raises an error.
///

#pragma once

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const RNVPAVMuxerErrorDomain;

typedef NS_ERROR_ENUM(RNVPAVMuxerErrorDomain, RNVPAVMuxerErrorCode){
    RNVPAVMuxerErrorCodeInvalidState = 1,
    RNVPAVMuxerErrorCodeInvalidSpec = 2,
    RNVPAVMuxerErrorCodeWriterFailed = 3,
    RNVPAVMuxerErrorCodeAppendFailed = 4,
};

@interface RNVPAVMuxer : NSObject

/// Open the sink at @c path targeting H.264 in an MP4 container with the given
/// pixel dimensions and integer frame rate. A silent AAC audio track is also
/// authored. The target file must not already exist; callers are responsible
/// for deleting a prior file at the same path before calling.
- (BOOL)openAtPath:(NSString *)path
             width:(NSInteger)width
            height:(NSInteger)height
               fps:(NSInteger)fps
             error:(NSError *_Nullable __autoreleasing *)error;

/// Same as @c openAtPath: but without an audio track. Callers that drive a
/// long-running offline video pump (renderCompose) need this because
/// AVAssetWriter back-pressures the video input once the audio queue runs
/// dry — providing media data "at a similar rate" is required across all
/// inputs, and we have nothing to feed audio with until close. Without the
/// audio input the writer stops back-pressuring at the audio side and
/// the video pump can run end-to-end.
- (BOOL)openVideoOnlyAtPath:(NSString *)path
                      width:(NSInteger)width
                     height:(NSInteger)height
                        fps:(NSInteger)fps
                      error:(NSError *_Nullable __autoreleasing *)error;

/// Same as @c openVideoOnlyAtPath: but also forwards the source asset's
/// container-level metadata into the output's @c moov atom. Use the
/// passthrough form (this method) on compose-on-clip paths so the
/// source's title / creation-date / custom user-data items survive the
/// round trip.
///
/// AVAssetWriter requires @c metadata to be set before
/// @c startWriting, so it can't be applied via a setter after the
/// existing open call — hence the dedicated overload.
- (BOOL)openVideoOnlyAtPath:(NSString *)path
                      width:(NSInteger)width
                     height:(NSInteger)height
                        fps:(NSInteger)fps
                   metadata:(NSArray<AVMetadataItem *> *_Nullable)metadata
                      error:(NSError *_Nullable __autoreleasing *)error;

/// Append a single pre-rendered pixel buffer at the given presentation time.
/// Callers must ensure PTS is monotonically non-decreasing across calls. The
/// pixel buffer must be in a format compatible with the adaptor (32BGRA).
- (BOOL)appendPixelBuffer:(CVPixelBufferRef)pixelBuffer
         presentationTime:(CMTime)pts
                    error:(NSError *_Nullable __autoreleasing *)error;

/// @c YES when the underlying @c AVAssetWriterInput is willing to accept
/// another frame right now. Goes @c NO when the encoder back-pressures its
/// internal queue (common on the simulator at small resolutions). Exposed so
/// render loops that need to stay responsive to external stop signals can
/// spin-wait on their own terms instead of blocking inside
/// @c appendPixelBuffer's 30s deadline.
@property(nonatomic, readonly) BOOL videoInputIsReady;

/// Finalize the file. Writes a silent audio segment spanning
/// [0, lastPts + 1/fps) and closes the underlying AVAssetWriter. Blocks the
/// calling thread until the writer flushes. Safe to call exactly once per
/// successful open; after this the instance cannot be reopened.
- (BOOL)closeWithError:(NSError *_Nullable __autoreleasing *)error;

@end

NS_ASSUME_NONNULL_END
