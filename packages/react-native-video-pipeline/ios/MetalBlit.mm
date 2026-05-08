///
/// MetalBlit.mm — see MetalBlit.h for the contract.
///

#import "MetalBlit.h"

#import <Metal/Metal.h>

NSErrorDomain const RNVPMetalBlitErrorDomain = @"RNVPMetalBlitErrorDomain";

namespace {

NSError *makeError(RNVPMetalBlitErrorCode code, NSString *message) {
  return [NSError errorWithDomain:RNVPMetalBlitErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

/// Cached pair so we don't rebuild the CVMetalTextureCache on every frame —
/// the worklet pump calls into this class ~fps times per second. The cache
/// is keyed on `MTLDevice`; we only ever use the system default, so a single
/// cache suffices. Command queue is similarly per-process.
struct MetalState {
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  CVMetalTextureCacheRef cache;
};

MetalState *sharedMetalState(NSError *_Nullable __autoreleasing *error) {
  static dispatch_once_t once;
  static MetalState *state = nullptr;
  static NSError *initError = nil;
  dispatch_once(&once, ^{
    MetalState *s = new MetalState();
    s->device = MTLCreateSystemDefaultDevice();
    if (s->device == nil) {
      initError = makeError(
          RNVPMetalBlitErrorCodeMetalUnavailable,
          @"MTLCreateSystemDefaultDevice returned nil — this host has no "
          @"Metal-capable GPU. The T053b GPU fast path is unavailable; the "
          @"drawWithSkia helper will fall back to the CPU readback path.");
      delete s;
      return;
    }
    s->queue = [s->device newCommandQueue];
    if (s->queue == nil) {
      initError = makeError(RNVPMetalBlitErrorCodeMetalUnavailable,
                            @"MTLDevice newCommandQueue returned nil.");
      delete s;
      return;
    }
    CVReturn cv = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL,
                                            s->device, NULL, &s->cache);
    if (cv != kCVReturnSuccess || s->cache == NULL) {
      initError = makeError(
          RNVPMetalBlitErrorCodeTextureCacheFailed,
          [NSString stringWithFormat:
                        @"CVMetalTextureCacheCreate failed with CVReturn=%d.",
                        (int)cv]);
      delete s;
      return;
    }
    state = s;
  });
  if (state == nullptr) {
    if (error && initError != nil) {
      *error = initError;
    }
    return nullptr;
  }
  return state;
}

} // namespace

@implementation RNVPMetalBlit

+ (BOOL)isMetalAvailable {
  NSError *ignore = nil;
  return sharedMetalState(&ignore) != nullptr;
}

+ (BOOL)blitFromMetalTexturePtr:(uintptr_t)mtlTexturePtr
                  toPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          error:(NSError *_Nullable __autoreleasing *)error {
  if (mtlTexturePtr == 0 || pixelBuffer == NULL) {
    if (error) {
      *error = makeError(
          RNVPMetalBlitErrorCodeInvalidSpec,
          @"mtlTexturePtr must be non-zero and pixelBuffer must be non-NULL.");
    }
    return NO;
  }

  if (CVPixelBufferGetIOSurface(pixelBuffer) == NULL) {
    if (error) {
      *error = makeError(
          RNVPMetalBlitErrorCodeInvalidSpec,
          @"destination CVPixelBuffer must be IOSurface-backed so the Metal "
          @"texture cache can wrap it without a CPU copy.");
    }
    return NO;
  }

  MetalState *state = sharedMetalState(error);
  if (state == nullptr) {
    return NO;
  }

  // Treat the incoming pointer as a non-owning `id<MTLTexture>`. The caller
  // (worklet runtime or XCTest) retains ownership — we never release.
  id<MTLTexture> source = (__bridge id<MTLTexture>)(void *)mtlTexturePtr;
  const NSUInteger srcW = source.width;
  const NSUInteger srcH = source.height;
  const size_t dstW = CVPixelBufferGetWidth(pixelBuffer);
  const size_t dstH = CVPixelBufferGetHeight(pixelBuffer);
  if (srcW != dstW || srcH != dstH) {
    if (error) {
      *error = makeError(
          RNVPMetalBlitErrorCodeDimensionMismatch,
          [NSString stringWithFormat:
                        @"source %lux%lu must match destination %zux%zu.",
                        (unsigned long)srcW, (unsigned long)srcH, dstW, dstH]);
    }
    return NO;
  }

  // Wrap the destination CVPixelBuffer as an MTLTexture on the same device.
  // BGRA8Unorm matches the 32BGRA CVPixelBuffer layout produced by the
  // muxer's pixel-buffer pool. Skia defaults its iOS offscreen surfaces to
  // BGRA8 premul, so source and destination pixel formats align.
  CVMetalTextureRef cvMetalTex = NULL;
  CVReturn cv = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, state->cache, pixelBuffer, NULL,
      MTLPixelFormatBGRA8Unorm, dstW, dstH, 0, &cvMetalTex);
  if (cv != kCVReturnSuccess || cvMetalTex == NULL) {
    if (error) {
      *error = makeError(
          RNVPMetalBlitErrorCodeTextureCacheFailed,
          [NSString
              stringWithFormat:
                  @"CVMetalTextureCacheCreateTextureFromImage failed with "
                  @"CVReturn=%d.",
                  (int)cv]);
    }
    return NO;
  }

  id<MTLTexture> destination = CVMetalTextureGetTexture(cvMetalTex);
  if (destination == nil) {
    CFRelease(cvMetalTex);
    if (error) {
      *error = makeError(
          RNVPMetalBlitErrorCodeTextureCacheFailed,
          @"CVMetalTextureGetTexture returned nil for the wrapped buffer.");
    }
    return NO;
  }

  id<MTLCommandBuffer> cmdBuf = [state->queue commandBuffer];
  id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
  if (cmdBuf == nil || blit == nil) {
    CFRelease(cvMetalTex);
    if (error) {
      *error = makeError(
          RNVPMetalBlitErrorCodeEncoderFailed,
          @"MTLCommandQueue commandBuffer / blitCommandEncoder returned nil.");
    }
    return NO;
  }

  const MTLOrigin origin = MTLOriginMake(0, 0, 0);
  const MTLSize size = MTLSizeMake(dstW, dstH, 1);
  [blit copyFromTexture:source
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:origin
             sourceSize:size
              toTexture:destination
       destinationSlice:0
       destinationLevel:0
      destinationOrigin:origin];
  [blit endEncoding];
  [cmdBuf commit];
  [cmdBuf waitUntilCompleted];

  NSError *cmdError = cmdBuf.error;
  CFRelease(cvMetalTex);

  if (cmdError != nil) {
    if (error) {
      *error = makeError(
          RNVPMetalBlitErrorCodeEncoderFailed,
          [NSString stringWithFormat:@"Metal blit command failed: %@",
                                     cmdError.localizedDescription]);
    }
    return NO;
  }

  return YES;
}

@end
