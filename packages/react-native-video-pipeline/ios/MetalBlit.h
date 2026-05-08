///
/// MetalBlit.h
///
/// T053b GPU fast path — zero-copy handoff from a Skia-drawn `id<MTLTexture>`
/// into an IOSurface-backed `CVPixelBuffer` that `RNVPAVMuxer` will append
/// without a CPU readback.
///
/// Contract:
///   - Caller (the worklet-runtime pump or a test) holds a source
///     `id<MTLTexture>` whose backing GPU memory already contains the frame
///     pixels. Skia exposes this via `SkSurface::getNativeTextureUnstable()`
///     — the returned handle is the Skia offscreen surface's color attachment,
///     valid for the lifetime of the surface.
///   - Destination is a BGRA 32-bit IOSurface-backed `CVPixelBuffer`, usually
///     dequeued from the `AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool`
///     owned by `RNVPAVMuxer`.
///   - The blit wraps the destination `CVPixelBuffer` as a second `MTLTexture`
///     on the same Metal device Skia uses (default system device, matches
///     Skia's `MTLCreateSystemDefaultDevice`), schedules an
///     `MTLBlitCommandEncoder copyFromTexture:toTexture:` on a private command
///     queue, then synchronises via `waitUntilCompleted` before returning.
///
/// Thread + device invariants:
///   - Skia (Ganesh-Metal) uses the default system device. This class asserts
///     the same, so the two textures are guaranteed to share an `MTLDevice`
///     and the blit succeeds without a cross-device copy.
///   - `waitUntilCompleted` is the coarsest sync available. An `MTLSharedEvent`
///     between Skia's queue and ours is a later optimisation — for the
///     single-frame blit we perform per tick the coarse sync is not on the
///     critical path compared to H.264 encode.
///
/// Android deferred: T053b is iOS-only. The Android parallel task lands when
/// either Skia exposes a `MakeSurfaceFromAHardwareBuffer`-style factory or
/// Graphite unlocks a direct-MediaCodec-surface path.
///

#pragma once

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const RNVPMetalBlitErrorDomain;

typedef NS_ERROR_ENUM(RNVPMetalBlitErrorDomain, RNVPMetalBlitErrorCode){
    RNVPMetalBlitErrorCodeInvalidSpec = 1,
    RNVPMetalBlitErrorCodeMetalUnavailable = 2,
    RNVPMetalBlitErrorCodeTextureCacheFailed = 3,
    RNVPMetalBlitErrorCodeDimensionMismatch = 4,
    RNVPMetalBlitErrorCodeEncoderFailed = 5,
};

@interface RNVPMetalBlit : NSObject

/// Blit a source `id<MTLTexture>` into a destination `CVPixelBuffer`.
///
/// @param mtlTexturePtr  Non-owning pointer to an `id<MTLTexture>` (typically
///                       from Skia's `getNativeTextureUnstable`). Must be on
///                       `MTLCreateSystemDefaultDevice()`. Must be 0 for an
///                       invalid-spec rejection path.
/// @param pixelBuffer    IOSurface-backed 32BGRA destination. Dimensions must
///                       match the source texture's width/height.
/// @param error          Populated on failure with an RNVPMetalBlit error.
/// @return YES on success, NO on failure.
+ (BOOL)blitFromMetalTexturePtr:(uintptr_t)mtlTexturePtr
                  toPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          error:(NSError *_Nullable __autoreleasing *)error;

/// Returns YES if the host has a usable Metal device. Headless CI agents or
/// machines without a GPU return NO — callers should skip the fast path in
/// that case. Intended for XCTest skip-guards; production worklet pumps
/// should trust the general-case YES.
+ (BOOL)isMetalAvailable;

@end

NS_ASSUME_NONNULL_END
