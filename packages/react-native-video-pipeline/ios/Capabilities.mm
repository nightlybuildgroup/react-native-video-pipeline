///
/// Capabilities.mm — see Capabilities.h for the contract.
///

#import "Capabilities.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <os/lock.h>
#import <os/log.h>

@implementation RNVPEncoderCapabilities {
  NSArray<NSString *> *_codecs;
  NSInteger _maxWidth;
  NSInteger _maxHeight;
  double _maxFps;
  NSInteger _maxBitrate;
  BOOL _hdr;
}

- (instancetype)initWithCodecs:(NSArray<NSString *> *)codecs
                      maxWidth:(NSInteger)maxWidth
                     maxHeight:(NSInteger)maxHeight
                        maxFps:(double)maxFps
                    maxBitrate:(NSInteger)maxBitrate
                           hdr:(BOOL)hdr {
  if ((self = [super init])) {
    _codecs = [codecs copy];
    _maxWidth = maxWidth;
    _maxHeight = maxHeight;
    _maxFps = maxFps;
    _maxBitrate = maxBitrate;
    _hdr = hdr;
  }
  return self;
}

- (NSArray<NSString *> *)codecs { return _codecs; }
- (NSInteger)maxWidth { return _maxWidth; }
- (NSInteger)maxHeight { return _maxHeight; }
- (double)maxFps { return _maxFps; }
- (NSInteger)maxBitrate { return _maxBitrate; }
- (BOOL)hdr { return _hdr; }

@end

namespace {

// Subsystem chosen to match the bundle id used elsewhere in the library so
// Instruments/Console filtering groups RNVP logs together. Fine-grained
// category tag lets the capabilities probe stand on its own in log streams.
os_log_t rnvpCapabilitiesLog(void) {
  static dispatch_once_t once;
  static os_log_t log;
  dispatch_once(&once, ^{
    log = os_log_create("com.unbogify.rnvp", "Capabilities");
  });
  return log;
}

// Attempt to construct a VTCompressionSession for the given
// (width, height, codec, pixel-format) tuple. Returns @c YES iff
// @c VTCompressionSessionCreate returned @c noErr — the session is
// immediately invalidated and released so the probe leaves no encoder
// state allocated. Encoder specification is left @c NULL so VideoToolbox
// picks the best available implementation (hardware where supported, a
// software fallback otherwise) — the library only cares whether *any*
// encoder for the codec exists, not which one.
BOOL canCreateEncoder(int32_t width,
                      int32_t height,
                      CMVideoCodecType codecType,
                      OSType pixelFormat) {
  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(pixelFormat),
    (id)kCVPixelBufferWidthKey : @(width),
    (id)kCVPixelBufferHeightKey : @(height),
  };
  VTCompressionSessionRef session = NULL;
  const OSStatus status = VTCompressionSessionCreate(
      kCFAllocatorDefault, width, height, codecType,
      /*encoderSpecification=*/NULL,
      (__bridge CFDictionaryRef)pbAttrs,
      /*compressedDataAllocator=*/NULL,
      /*outputCallback=*/NULL,
      /*outputCallbackRefCon=*/NULL, &session);
  if (session != NULL) {
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
  }
  return status == noErr;
}

// Protected by g_lock. Populated on the first call to +probe; cleared only
// by +resetCacheForTesting. Strong ARC retain: the static global owns the
// single cached snapshot for the process lifetime.
RNVPEncoderCapabilities *g_cached = nil;
NSInteger g_probeCount = 0;
os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;

RNVPEncoderCapabilities *runProbe(void) {
  NSMutableArray<NSString *> *codecs = [NSMutableArray arrayWithCapacity:2];
  // 8-bit 4:2:0 NV12 is the canonical probe pixel format — every iOS/macOS
  // encoder that exists at all accepts it, so a failure here cleanly means
  // "the codec is not available" rather than "this specific pixel format
  // isn't supported by an otherwise-present encoder".
  const OSType sdrPixel = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  if (canCreateEncoder(640, 480, kCMVideoCodecType_H264, sdrPixel)) {
    [codecs addObject:@"h264"];
  }
  if (canCreateEncoder(640, 480, kCMVideoCodecType_HEVC, sdrPixel)) {
    [codecs addObject:@"hevc"];
  }

  // Probe 4K at H.264; fall back to 1080p. Every iPhone 7 and later reports
  // 4K here, including every iPhone 13-class simulator this task is
  // verified against.
  NSInteger maxW = 1920;
  NSInteger maxH = 1080;
  if (canCreateEncoder(3840, 2160, kCMVideoCodecType_H264, sdrPixel)) {
    maxW = 3840;
    maxH = 2160;
  }

  // HDR means "HEVC with a 10-bit pixel format can be created". The
  // AVDemuxer side identifies HDR sources through HLG / PQ transfer
  // characteristics — both live inside 10-bit HEVC on the iOS encoder
  // path, so this probe is the encode counterpart of that decode check.
  const OSType hdr10Pixel = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
  const BOOL hdr = [codecs containsObject:@"hevc"] &&
                   canCreateEncoder(1920, 1080, kCMVideoCodecType_HEVC,
                                    hdr10Pixel);

  // maxFps / maxBitrate: conservative ceilings that every iOS 13+ class
  // device supporting the above resolutions is known to handle. Not
  // probed per-device because VideoToolbox does not expose a portable
  // "will this encoder accept N fps / M bitrate" API — the values below
  // are the documented H.264 Level 5.2 bitrate cap and a 60 fps ceiling
  // that matches all known hardware encoders. A later task can refine
  // these via a per-chip lookup once a concrete consumer depends on
  // headroom above 60fps.
  const double maxFps = 60.0;
  const NSInteger maxBitrate = 120 * 1000 * 1000;

  return [[RNVPEncoderCapabilities alloc] initWithCodecs:codecs
                                                maxWidth:maxW
                                               maxHeight:maxH
                                                  maxFps:maxFps
                                              maxBitrate:maxBitrate
                                                     hdr:hdr];
}

} // namespace

@implementation RNVPCapabilities

+ (RNVPEncoderCapabilities *)probe {
  // Double-checked lookup: the common path (cache hit) performs a single
  // load under the lock and returns, keeping the steady-state cost at one
  // os_unfair_lock roundtrip.
  os_unfair_lock_lock(&g_lock);
  RNVPEncoderCapabilities *cached = g_cached;
  if (cached == nil) {
    g_probeCount += 1;
    os_log_info(rnvpCapabilitiesLog(),
                "Capabilities: probing encoders (call #%ld)",
                (long)g_probeCount);
    cached = runProbe();
    g_cached = cached;
    os_log_info(rnvpCapabilitiesLog(),
                "Capabilities: probe complete (codecs=%{public}@, "
                "%ldx%ld, hdr=%d)",
                cached.codecs, (long)cached.maxWidth,
                (long)cached.maxHeight, cached.hdr);
  }
  os_unfair_lock_unlock(&g_lock);
  return cached;
}

+ (NSInteger)probeCount {
  os_unfair_lock_lock(&g_lock);
  const NSInteger count = g_probeCount;
  os_unfair_lock_unlock(&g_lock);
  return count;
}

+ (void)resetCacheForTesting {
  os_unfair_lock_lock(&g_lock);
  g_cached = nil;
  g_probeCount = 0;
  os_unfair_lock_unlock(&g_lock);
}

@end
