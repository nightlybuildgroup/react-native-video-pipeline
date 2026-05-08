///
/// Thumbnailer.h
///
/// Obj-C entry point for the iOS probe path `Video.thumbnail`. Wraps
/// @c AVAssetImageGenerator so the caller gets a single JPEG file written at
/// @p outputURL for the frame nearest @p atSec. Source rotation is applied to
/// the rendered pixels (@c appliesPreferredTrackTransform = YES) — the output
/// JPEG is upright regardless of the container's preferredTransform. An
/// optional resize bounding box scales the output while preserving aspect
/// ratio (longest-side semantics, matching the JS-side @c Size contract).
///
/// Invoked by @c HybridVideoPipeline::thumbnail in VideoPipeline.mm. Also
/// callable directly from XCTest — tests drive the full AVFoundation chain
/// without needing a JS runtime or the Nitro boundary.
///

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const RNVPThumbnailerErrorDomain;

typedef NS_ERROR_ENUM(RNVPThumbnailerErrorDomain, RNVPThumbnailerErrorCode){
    RNVPThumbnailerErrorCodeInvalidSpec = 1,
    RNVPThumbnailerErrorCodeNotFound = 2,
    RNVPThumbnailerErrorCodeGenerationFailed = 3,
    RNVPThumbnailerErrorCodeWriteFailed = 4,
};

@interface RNVPThumbnailer : NSObject

/// Extract a single JPEG frame at @p atSec from @p sourceURL and write it to
/// @p outputURL. Values of @p resizeWidth or @p resizeHeight <= 0 are treated
/// as "not specified". When both are specified the output is scaled to fit
/// inside the @c (resizeWidth, resizeHeight) bounding box, preserving source
/// aspect ratio; when only one is specified the other dimension scales
/// proportionally. @p atSec is clamped into @c [0, duration] — AVFoundation
/// itself happily accepts out-of-range times and returns the nearest-on-disk
/// frame, which matches the convenience contract for this API.
///
/// Returns @c YES on success; on failure populates @p error and ensures no
/// partial output file is left behind.
+ (BOOL)generateThumbnailFromURL:(NSURL *)sourceURL
                           toURL:(NSURL *)outputURL
                           atSec:(double)atSec
                     resizeWidth:(double)resizeWidth
                    resizeHeight:(double)resizeHeight
                           error:(NSError *_Nullable __autoreleasing *)error;

@end

NS_ASSUME_NONNULL_END
