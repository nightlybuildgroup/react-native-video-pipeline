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

// ---------------------------------------------------------------------------
// HDR-preserving compose (#92). The counterpart to the SDR path above: instead
// of tone-mapping an HDR (HLG/PQ, bt2020) source down to 8-bit sRGB, it renders
// the source into a 10-bit-capable buffer in an extended-range bt2020 working
// space, preserving luminance above SDR white. Selected when the caller opts
// into `output.colorRange: 'hdr'` (#94) AND the encoder can carry HDR.
// ---------------------------------------------------------------------------

/// Create the HDR working/output color space compose materializes HDR source
/// frames into: `kCGColorSpaceExtendedLinearITUR_2020` — the bt2020 primaries
/// in a *linear*, extended range (values may exceed 1.0 for HDR highlights).
///
/// Deliberately the extended-linear space rather than the named HLG/PQ spaces
/// (`kCGColorSpaceITUR_2100_HLG` / `...PQ`): those are iOS 14.0+, and the
/// library targets iOS 13+. Extended-linear bt2020 is iOS 12.3-safe and
/// lossless for the materialize step.
///
/// **Open question for the end-to-end wiring (#92 part 2):** the materialized
/// buffer holds *linear-light* bt2020 (tagged as such by
/// `RNVPComposeRenderSourceToHDR`), whereas the Main10 encoder is tagged HLG.
/// Whether VideoToolbox converts linear→HLG on the strength of the buffer's
/// transfer attachment, or whether the pipeline must apply the HLG OOTF before
/// append, is a transfer-correctness question that needs real HDR-device
/// luminance verification — the host tests here prove the range *survives* and
/// the encoder *accepts* the format, not that the end-to-end transfer is right.
///
/// Returns a retained color space — the caller owns it and must
/// `CGColorSpaceRelease` it.
CGColorSpaceRef RNVPComposeHDRWorkingColorSpaceCreate(void)
    CF_RETURNS_RETAINED;

/// Render a source `CIImage` into a 10-bit / half-float `target` pixel buffer
/// over `bounds` in the extended-linear bt2020 working space — **no** tone-map,
/// unlike `RNVPComposeRenderSourceToSDR`. An HDR highlight that clips to 255 in
/// 8-bit sRGB survives here as a channel value above 1.0 (representable in a
/// `kCVPixelFormatType_64RGBAHalf` target), so the worklet — and ultimately the
/// Main10 encoder — see the full dynamic range.
///
/// `target` must be a wide buffer (half-float RGBA or 10-bit YUV); handing this
/// an 8-bit buffer would clamp the very range it exists to preserve.
void RNVPComposeRenderSourceToHDR(CIContext* ciContext,
                                  CIImage* source,
                                  CVPixelBufferRef target,
                                  CGRect bounds);

/// The pixel-format + sink decision compose's null-input (worklet-generated)
/// branch makes for a given output color range. Extracted from
/// `VideoPipeline.mm` — which the host XCTest harness excludes (Nitro deps) —
/// so the branch-selection contract is host-testable in isolation (#92).
typedef struct {
  BOOL valid;          ///< NO for a contradictory request (HDR + explicit H.264).
  BOOL hdr;            ///< route to the Main10 HLG sink (vs the SDR H.264 sink).
  OSType pixelFormat;  ///< CVPixelBuffer format for the worklet target.
} RNVPComposeSynthesizePlan;

/// Decide the plan for a worklet-generated (null-input) compose frame:
///
/// - SDR (or no HDR request): 8-bit `kCVPixelFormatType_32BGRA` into the H.264
///   sink — today's behavior, unchanged.
/// - HDR: half-float `kCVPixelFormatType_64RGBAHalf` (the `rgbaFp16` worklet
///   target, #99) into the HEVC Main10 HLG sink (#92).
/// - HDR requested with an explicit H.264 codec: `valid == NO`. HDR needs
///   Main10/HEVC; silently overriding the caller's codec would hide the
///   conflict, so the caller rejects with an actionable InvalidSpec instead.
///
/// @param hdrRequested  `output.colorRange == 'hdr'`.
/// @param codecIsH264   `output.codec` resolved explicitly to h264.
RNVPComposeSynthesizePlan RNVPComposeSynthesizePlanFor(BOOL hdrRequested,
                                                       BOOL codecIsH264);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
