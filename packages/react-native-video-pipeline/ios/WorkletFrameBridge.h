///
/// WorkletFrameBridge.h
///
/// Library-internal bridge that converts a CPU bitmap produced by the
/// consumer's Skia worklet into a CoreVideo pixel buffer suitable for
/// `RNVPAVMuxer.appendPixelBuffer:`. Keeps Skia out of the library
/// (`CLAUDE.md` — "Zero Skia in the library itself"): consumers call
/// `SkSurface::readPixels` on their side, hand raw bytes across the Nitro
/// boundary, and this class takes it from there.
///
/// Scope for T019 is deliberately narrow: CPU-side bitmap in RGBA8888 or
/// BGRA8888 → 32BGRA CVPixelBuffer. GPU-texture handoff (IOSurface /
/// CVMetalTextureCache sharing with the Skia context) lands in T053b.
///

#pragma once

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const RNVPWorkletFrameBridgeErrorDomain;

typedef NS_ERROR_ENUM(RNVPWorkletFrameBridgeErrorDomain,
                      RNVPWorkletFrameBridgeErrorCode){
    RNVPWorkletFrameBridgeErrorCodeInvalidSpec = 1,
    RNVPWorkletFrameBridgeErrorCodeAllocationFailed = 2,
};

/// Pixel layout of the input bitmap. The bridge always produces BGRA8888 as
/// output (AVMuxer's adaptor source format). Alpha is treated as premultiplied
/// in both directions — the bridge never re-associates or un-multiplies.
typedef NS_ENUM(NSInteger, RNVPBitmapFormat) {
  /// Skia default for `readPixels` on Android and any kRGBA_8888_SkColorType
  /// surface — channels in memory: R, G, B, A.
  RNVPBitmapFormatRGBA8888Premultiplied,
  /// Skia's kN32_SkColorType on iOS / already-native CoreVideo layout —
  /// channels in memory: B, G, R, A.
  RNVPBitmapFormatBGRA8888Premultiplied,
};

@interface RNVPWorkletFrameBridge : NSObject

/// Convert a CPU bitmap into a 32BGRA CVPixelBuffer.
///
/// @param bytes    Pointer to the top-left pixel of the bitmap. Must remain
///                 valid for the duration of the call.
/// @param width    Pixel width; must be > 0.
/// @param height   Pixel height; must be > 0.
/// @param rowBytes Source row stride in bytes; must be >= @c width*4 .
/// @param format   Source channel order.
///
/// Returns a CF-retained pixel buffer (the `CF_RETURNS_RETAINED` annotation
/// tells the static analyzer the caller owns it — pair with
/// `CVPixelBufferRelease`). Returns NULL on failure and populates @c error.
+ (CVPixelBufferRef _Nullable)
    pixelBufferFromBytes:(const void *)bytes
                   width:(NSInteger)width
                  height:(NSInteger)height
                rowBytes:(NSInteger)rowBytes
                  format:(RNVPBitmapFormat)format
                   error:(NSError *_Nullable __autoreleasing *)error
    CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
