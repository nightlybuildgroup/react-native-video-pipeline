#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Create the SDR output color space compose materializes source frames into.
/// Returns a retained `kCGColorSpaceSRGB` reference — the caller owns it and
/// must `CGColorSpaceRelease` it. Extracted so the compose color contract has
/// a single source of truth that the host XCTest harness can exercise (issue
/// #86).
CGColorSpaceRef RNVPComposeSDRColorSpaceCreate(void)
    CF_RETURNS_RETAINED;

/// Render a source `CIImage` into the 32BGRA `target` pixel buffer over
/// `bounds`, tone-mapping HDR (HLG/PQ, bt2020) sources down to SDR sRGB.
///
/// The compose pump is end-to-end 8-bit BGRA. Rendering an HDR CIImage with
/// `colorSpace:nil` writes the HLG/PQ signal straight into 8-bit with **no**
/// transfer conversion, so HDR mid-tones — encoded far below their sRGB
/// equivalents — crush to a dark, washed-out frame before the consumer worklet
/// ever sees them (issue #86). Handing CoreImage an explicit sRGB output color
/// space makes it perform the HDR→SDR tone-map. SDR (`bt709`) sources are
/// unaffected: converting sRGB→sRGB is a no-op. Tone-mapped SDR is the only
/// viable compose output here without a 10-bit pixel pipeline.
///
/// `ciContext` is reused across frames by the caller (Metal setup is
/// expensive); this helper only owns the per-call color space.
void RNVPComposeRenderSourceToSDR(CIContext* ciContext,
                                  CIImage* source,
                                  CVPixelBufferRef target,
                                  CGRect bounds);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
