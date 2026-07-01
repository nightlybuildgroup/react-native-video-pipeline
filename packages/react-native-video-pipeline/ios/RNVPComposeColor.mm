#import "RNVPComposeColor.h"

// Standalone (Nitro-free) compose color helpers, kept in their own translation
// unit so the host XCTest harness (`yarn test:native`, which cannot compile
// VideoPipeline.mm's Nitro-generated dependencies) can exercise the HDR→SDR
// tone-map contract directly. VideoPipeline.mm's `renderCompose` delegates its
// per-frame source materialization here so there is a single source of truth
// for compose's output color space (issue #86).

CGColorSpaceRef RNVPComposeSDRColorSpaceCreate(void) {
  return CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
}

void RNVPComposeRenderSourceToSDR(CIContext* ciContext,
                                  CIImage* source,
                                  CVPixelBufferRef target,
                                  CGRect bounds) {
  CGColorSpaceRef sdr = RNVPComposeSDRColorSpaceCreate();
  [ciContext render:source
      toCVPixelBuffer:target
               bounds:bounds
           colorSpace:sdr];
  CGColorSpaceRelease(sdr);
}
