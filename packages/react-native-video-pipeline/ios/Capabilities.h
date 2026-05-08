///
/// Capabilities.h
///
/// Obj-C entry point for the iOS encoder-capability probe `Video.capabilities`.
/// Walks VideoToolbox to decide which codecs + dimensions + HDR modes the
/// current device can actually encode, caches the result per-process, and
/// hands back an @c RNVPEncoderCapabilities snapshot on every call.
///
/// The probe is implemented by creating transient @c VTCompressionSession
/// instances at representative (codec, width, height, pixel-format) tuples
/// and inspecting whether @c VTCompressionSessionCreate returns @c noErr.
/// Each probed session is invalidated and released before the method
/// returns, so the probe carries no steady-state cost beyond the first call.
///
/// Invoked by @c HybridVideoPipeline::capabilities in VideoPipeline.mm. Also
/// callable directly from XCTest so caching behavior (identity of the
/// cached instance, probe count) can be observed without a JS runtime.
///

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Immutable snapshot returned from @c +[RNVPCapabilities probe]. Field
/// semantics mirror the nitrogen-generated @c EncoderCaps struct:
///   - @c codecs contains the string tags @c "h264" and/or @c "hevc". H.264
///     is required for any iOS 13+ device to ship a working video pipeline;
///     absence would indicate a broken simulator, not a real device class.
///   - @c maxWidth / @c maxHeight report the largest 16-aligned dimensions
///     @c VTCompressionSessionCreate accepts for H.264. Typical values are
///     @c 3840x2160 (iPhone 7+) with a @c 1920x1080 fallback for older chips.
///   - @c maxFps / @c maxBitrate are conservative v0.1 ceilings
///     (@c 60 fps / @c 120 Mbps) held consistent across device classes —
///     device-class refinement lands in a later task once there is a
///     concrete consumer that depends on headroom above 1080p60.
///   - @c hdr is YES only when HEVC with a 10-bit pixel format can be
///     created at @c 1920x1080. Matches the AVDemuxer probe's HDR
///     contract (HLG/PQ transfer characteristics).
@interface RNVPEncoderCapabilities : NSObject
@property(nonatomic, readonly) NSArray<NSString *> *codecs;
@property(nonatomic, readonly) NSInteger maxWidth;
@property(nonatomic, readonly) NSInteger maxHeight;
@property(nonatomic, readonly) double maxFps;
@property(nonatomic, readonly) NSInteger maxBitrate;
@property(nonatomic, readonly) BOOL hdr;
@end

@interface RNVPCapabilities : NSObject

/// Probe the device's encoder capabilities. The first call runs the probe
/// synchronously (~a few VTCompressionSessionCreate+destroy pairs, under a
/// few milliseconds on iPhone-class hardware); subsequent calls return the
/// identical cached instance. Safe to call from any thread.
+ (RNVPEncoderCapabilities *)probe;

/// Number of times the underlying VT probe has actually run. Stays at 1
/// after the first @c +probe call, regardless of how many callers hit the
/// method. XCTests observe this to confirm per-process caching — the
/// production code path only inspects the returned object.
+ (NSInteger)probeCount;

/// Reset the cache. Intended solely for XCTests that want to exercise the
/// first-call path more than once; never called from production code.
+ (void)resetCacheForTesting;

@end

NS_ASSUME_NONNULL_END
