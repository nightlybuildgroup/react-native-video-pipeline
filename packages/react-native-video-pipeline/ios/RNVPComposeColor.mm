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
  // Extended-range LINEAR bt2020 — iOS 12.3+ (the named ITUR_2100 HLG/PQ spaces
  // are iOS 14.0+, and kCGColorSpaceLinearITUR_2020 is iOS 15+, so neither is
  // usable at the iOS 13 floor). Extended range so HDR highlights survive as
  // > 1.0. This name is available on every OS the library supports, so there is
  // no fallback: a NULL here would be a platform bug, not a supported path.
  return CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearITUR_2020);
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

  // Self-describe the result so downstream code (and the encoder) can see what
  // the buffer actually holds: bt2020 primaries, a LINEAR transfer, bt2020
  // matrix. This is deliberately NOT the encoder's HLG transfer — reconciling
  // the linear working space with the encoder's HLG/PQ output tag (either a
  // linear→HLG conversion before append, or letting VideoToolbox convert on the
  // strength of these attachments) is the open correctness question for the
  // end-to-end wiring (#92 part 2), and needs real HDR-device luminance
  // verification. Tagging honestly here is the first step toward that.
  CVBufferSetAttachment(target, kCVImageBufferColorPrimariesKey,
                        kCVImageBufferColorPrimaries_ITU_R_2020,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(target, kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_Linear,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(target, kCVImageBufferYCbCrMatrixKey,
                        kCVImageBufferYCbCrMatrix_ITU_R_2020,
                        kCVAttachmentMode_ShouldPropagate);
}

RNVPComposeSynthesizePlan RNVPComposeSynthesizePlanFor(BOOL hdrRequested,
                                                       BOOL codecIsH264) {
  RNVPComposeSynthesizePlan plan;
  // HDR requires the Main10/HEVC sink; an explicit H.264 request is a genuine
  // conflict the caller must surface rather than silently override.
  if (hdrRequested && codecIsH264) {
    plan.valid = NO;
    plan.hdr = NO;
    plan.pixelFormat = kCVPixelFormatType_32BGRA;
    return plan;
  }
  plan.valid = YES;
  plan.hdr = hdrRequested ? YES : NO;
  plan.pixelFormat =
      hdrRequested ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA;
  return plan;
}
