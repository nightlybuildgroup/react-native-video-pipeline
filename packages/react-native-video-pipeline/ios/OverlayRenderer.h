///
/// OverlayRenderer.h
///
/// Pre-rasterizes a set of static overlays once at setup time, then
/// composites the active ones onto each decoded frame during the transcode
/// loop. Two variants are supported:
///
///   - @c RNVPImageOverlay — static bitmap overlay loaded from disk (T034).
///   - @c RNVPTextOverlay  — CATextLayer-rasterized text overlay (T035).
///
/// Both overlay variants flow through the same @c RNVPOverlayRenderer; the
/// renderer handles each one at init time by building a ready-to-composite
/// @c CIImage (already scaled, opacified/styled, and translated to its anchor
/// position). The per-frame call site is a single @c CISourceOverCompositing
/// chain per active overlay.
///
/// Coordinate convention: Core Image treats Y=0 as the bottom of the image.
/// The public anchor semantic exposes Y=0 as the TOP of the output frame
/// (matching the natural "screen" interpretation a JS caller reaches for).
/// The renderer does the Y flip internally so the overlay appears where the
/// caller expects.
///
/// Anchor math: for an overlay of size (w, h) on an output of size (W, H)
/// with anchor (ax, ay), the overlay's top-left screen position is
/// (ax·(W-w), ay·(H-h)) — "tl" lands at (0, 0), "br" lands at (W-w, H-h),
/// "center" lands at ((W-w)/2, (H-h)/2). This matches the behavior consumers
/// get from the public @c AnchorPreset shorthand.
///
/// Cross-platform parity with Android's Media3 @c TextOverlay is intentionally
/// perceptual, not pixel-identical — see docs/architecture.md. Consumers who need
/// pixel-identical cross-platform text rasterize a PNG themselves and pass it
/// as @c Overlay.Image.
///

#pragma once

#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const RNVPOverlayRendererErrorDomain;

typedef NS_ERROR_ENUM(RNVPOverlayRendererErrorDomain,
                      RNVPOverlayRendererErrorCode){
    RNVPOverlayRendererErrorCodeInvalidSpec = 1,
    RNVPOverlayRendererErrorCodeImageLoadFailed = 2,
    RNVPOverlayRendererErrorCodeTextRasterFailed = 3,
};

/// Mirrors the nitrogen-generated @c TextAlign enum ordinals.
typedef NS_ENUM(NSInteger, RNVPTextAlignment) {
  RNVPTextAlignmentLeft = 0,
  RNVPTextAlignmentCenter = 1,
  RNVPTextAlignmentRight = 2,
};

/// One static image overlay. All parameters correspond 1:1 to the JS
/// @c ImageOverlay type; the 0.0 sentinel on size fields matches the JS
/// "missing dimension" contract (at least one must be > 0).
@interface RNVPImageOverlay : NSObject
@property(nonatomic, readonly) NSURL *imageURL;
@property(nonatomic, readonly) double anchorX;
@property(nonatomic, readonly) double anchorY;
/// 0.0 → scale proportionally from the other dimension.
@property(nonatomic, readonly) double sizeW;
@property(nonatomic, readonly) double sizeH;
/// 1.0 default; clamped to [0, 1] at render time.
@property(nonatomic, readonly) double opacity;
@property(nonatomic, readonly) BOOL hasTimeRange;
@property(nonatomic, readonly) double startSec;
@property(nonatomic, readonly) double endSec;

- (instancetype)initWithImageURL:(NSURL *)imageURL
                         anchorX:(double)anchorX
                         anchorY:(double)anchorY
                           sizeW:(double)sizeW
                           sizeH:(double)sizeH
                         opacity:(double)opacity
                    hasTimeRange:(BOOL)hasTimeRange
                        startSec:(double)startSec
                          endSec:(double)endSec NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// One static text overlay. Mirrors the JS @c TextOverlay flattened into
/// primitive fields so the renderer can be driven from both the Nitro bridge
/// and raw Obj-C XCTests without pulling in the nitrogen-generated types.
///
/// @c colorString accepts the same forms as the JS @c TextStyle.color field:
///   - hex: @"#rgb", @"#rgba", @"#rrggbb", @"#rrggbbaa" (case-insensitive).
///   - css: @"rgb(r, g, b)" or @"rgba(r, g, b, a)" with r/g/b in [0, 255]
///     and a in [0, 1].
///
/// Missing @c fontFamily → platform system font. Shadow fields are honoured
/// only when @p hasShadow is YES.
@interface RNVPTextOverlay : NSObject
@property(nonatomic, readonly) NSString *text;
@property(nonatomic, readonly, nullable) NSString *fontFamily;
@property(nonatomic, readonly) double fontSize;
@property(nonatomic, readonly) NSString *colorString;
@property(nonatomic, readonly) BOOL weightBold;
@property(nonatomic, readonly) RNVPTextAlignment alignment;
@property(nonatomic, readonly) BOOL hasShadow;
@property(nonatomic, readonly, nullable) NSString *shadowColorString;
@property(nonatomic, readonly) double shadowBlur;
@property(nonatomic, readonly) double shadowDx;
@property(nonatomic, readonly) double shadowDy;
@property(nonatomic, readonly) double anchorX;
@property(nonatomic, readonly) double anchorY;
@property(nonatomic, readonly) BOOL hasTimeRange;
@property(nonatomic, readonly) double startSec;
@property(nonatomic, readonly) double endSec;

- (instancetype)initWithText:(NSString *)text
                  fontFamily:(nullable NSString *)fontFamily
                    fontSize:(double)fontSize
                 colorString:(NSString *)colorString
                  weightBold:(BOOL)weightBold
                   alignment:(RNVPTextAlignment)alignment
                   hasShadow:(BOOL)hasShadow
           shadowColorString:(nullable NSString *)shadowColorString
                  shadowBlur:(double)shadowBlur
                    shadowDx:(double)shadowDx
                    shadowDy:(double)shadowDy
                     anchorX:(double)anchorX
                     anchorY:(double)anchorY
                hasTimeRange:(BOOL)hasTimeRange
                    startSec:(double)startSec
                      endSec:(double)endSec NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Holds a vector of ready-to-composite CIImages keyed by the caller's
/// overlay index. A single @c -applyToFrame:atTimeSec: call applies every
/// currently-active overlay via Core Image's lazy filter graph — the result
/// is still a CIImage, so the caller (Transcoder.mm) can render it into a
/// destination pixel buffer in one pass.
@interface RNVPOverlayRenderer : NSObject

/// Designated initializer. Walks @p overlays in order, accepting any mixture
/// of @c RNVPImageOverlay and @c RNVPTextOverlay elements. Loads/rasterizes
/// each entry once, applies anchor math against @p targetSize, and stores the
/// prepared CIImage. Returns nil (and populates @p error) on any failure —
/// bad size, missing image file, text rasterization failure, or unknown
/// overlay class. Per-frame cost is constant in the number of active
/// overlays.
- (nullable instancetype)initWithOverlays:(NSArray *)overlays
                               targetSize:(CGSize)targetSize
                                    error:(NSError *_Nullable __autoreleasing *)error
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// @return YES when at least one overlay's time range covers @p timeSec.
/// Used by the transcoder to skip compositing entirely when no overlay is
/// active at the current frame.
- (BOOL)hasActiveOverlaysAtTimeSec:(double)timeSec;

/// Composite every active overlay onto @p frame in overlay-index order, as a
/// chain of @c CISourceOverCompositing filters. When no overlay is active
/// returns @p frame unchanged (no filter allocation).
- (CIImage *)applyToFrame:(CIImage *)frame atTimeSec:(double)timeSec;

@end

NS_ASSUME_NONNULL_END
