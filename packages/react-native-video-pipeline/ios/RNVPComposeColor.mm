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

CGColorSpaceRef RNVPComposeHDRWorkingColorSpaceCreate(void) {
  // Extended-range LINEAR bt2020 — iOS 13-safe (the named ITUR_2100 HLG/PQ
  // spaces are iOS 14.0+). Extended range so HDR highlights survive as > 1.0.
  CGColorSpaceRef space =
      CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearITUR_2020);
  if (space == NULL) {
    // Defensive fallback: plain (non-extended) linear bt2020 still keeps the
    // wide gamut, just without headroom above 1.0. Should not happen on any
    // supported OS, but never hand CoreImage a NULL space.
    space = CGColorSpaceCreateWithName(kCGColorSpaceLinearITUR_2020);
  }
  return space;
}

void RNVPComposeRenderSourceToHDR(CIContext* ciContext,
                                  CIImage* source,
                                  CVPixelBufferRef target,
                                  CGRect bounds) {
  CGColorSpaceRef hdr = RNVPComposeHDRWorkingColorSpaceCreate();
  [ciContext render:source
      toCVPixelBuffer:target
               bounds:bounds
           colorSpace:hdr];
  CGColorSpaceRelease(hdr);
}
