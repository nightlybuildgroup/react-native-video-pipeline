///
/// WorkletFrameBridge.mm — see WorkletFrameBridge.h for the contract.
///

#import "WorkletFrameBridge.h"

NSErrorDomain const RNVPWorkletFrameBridgeErrorDomain =
    @"RNVPWorkletFrameBridgeErrorDomain";

namespace {

NSError *makeError(RNVPWorkletFrameBridgeErrorCode code, NSString *message) {
  return [NSError errorWithDomain:RNVPWorkletFrameBridgeErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

} // namespace

@implementation RNVPWorkletFrameBridge

+ (CVPixelBufferRef)pixelBufferFromBytes:(const void *)bytes
                                   width:(NSInteger)width
                                  height:(NSInteger)height
                                rowBytes:(NSInteger)rowBytes
                                  format:(RNVPBitmapFormat)format
                                   error:
                                       (NSError *_Nullable __autoreleasing *)
                                           error {
  if (bytes == NULL || width <= 0 || height <= 0 || rowBytes < width * 4) {
    if (error) {
      *error = makeError(
          RNVPWorkletFrameBridgeErrorCodeInvalidSpec,
          @"bytes must be non-null; width/height must be positive; "
          @"rowBytes must be >= width*4.");
    }
    return NULL;
  }

  // Allocate an IOSurface-backed BGRA buffer so the AVAssetWriter adaptor can
  // import it without a CPU copy. Empty IOSurfacePropertiesKey is the
  // documented "please back this with an IOSurface, use defaults" signal.
  NSDictionary<NSString *, id> *attrs = @{
    (NSString *)kCVPixelBufferPixelFormatTypeKey :
        @(kCVPixelFormatType_32BGRA),
    (NSString *)kCVPixelBufferWidthKey : @(width),
    (NSString *)kCVPixelBufferHeightKey : @(height),
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  CVPixelBufferRef pb = NULL;
  CVReturn cv = CVPixelBufferCreate(kCFAllocatorDefault, (size_t)width,
                                    (size_t)height, kCVPixelFormatType_32BGRA,
                                    (__bridge CFDictionaryRef)attrs, &pb);
  if (cv != kCVReturnSuccess || pb == NULL) {
    if (error) {
      *error = makeError(
          RNVPWorkletFrameBridgeErrorCodeAllocationFailed,
          [NSString stringWithFormat:
                        @"CVPixelBufferCreate failed with CVReturn=%d.",
                        (int)cv]);
    }
    return NULL;
  }

  CVPixelBufferLockBaseAddress(pb, 0);
  uint8_t *dstBase = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
  const size_t dstStride = CVPixelBufferGetBytesPerRow(pb);
  const size_t rowCopyBytes = (size_t)width * 4;
  const uint8_t *srcBase = (const uint8_t *)bytes;

  for (NSInteger y = 0; y < height; y++) {
    const uint8_t *srcRow = srcBase + (size_t)y * (size_t)rowBytes;
    uint8_t *dstRow = dstBase + (size_t)y * dstStride;

    if (format == RNVPBitmapFormatBGRA8888Premultiplied) {
      memcpy(dstRow, srcRow, rowCopyBytes);
      continue;
    }

    // RGBA → BGRA: swap channels 0 and 2 per pixel, preserve A.
    for (NSInteger x = 0; x < width; x++) {
      const uint8_t *sp = srcRow + (size_t)x * 4;
      uint8_t *dp = dstRow + (size_t)x * 4;
      dp[0] = sp[2]; // B ← R
      dp[1] = sp[1]; // G
      dp[2] = sp[0]; // R ← B
      dp[3] = sp[3]; // A
    }
  }
  CVPixelBufferUnlockBaseAddress(pb, 0);
  return pb;
}

@end
