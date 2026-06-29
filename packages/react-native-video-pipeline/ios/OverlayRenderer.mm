///
/// OverlayRenderer.mm — see OverlayRenderer.h for the contract.
///

#import "OverlayRenderer.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>

#include <cmath>
#include <vector>

NSErrorDomain const RNVPOverlayRendererErrorDomain =
    @"RNVPOverlayRendererErrorDomain";

namespace {

NSError *makeError(RNVPOverlayRendererErrorCode code, NSString *message) {
  return [NSError errorWithDomain:RNVPOverlayRendererErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

// Load @p url as a CIImage via ImageIO. Returns nil on any failure; the
// caller rewraps the failure as a typed ImageLoadFailed error with the URL
// included so the JS boundary gets a useful message.
CIImage *loadImage(NSURL *url) {
  CGImageSourceRef src =
      CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
  if (src == NULL) return nil;
  CGImageRef cgImage = CGImageSourceCreateImageAtIndex(src, 0, NULL);
  CFRelease(src);
  if (cgImage == NULL) return nil;
  CIImage *image = [CIImage imageWithCGImage:cgImage];
  CGImageRelease(cgImage);
  return image;
}

// Resolve (sizeW, sizeH) against an intrinsic (naturalW, naturalH), honoring
// the "at least one provided; missing side scales proportionally" contract.
// Returns (0, 0) if neither side is provided (the renderer treats that as an
// invalid spec and errors out).
CGSize resolveTargetImageSize(double sizeW, double sizeH, double naturalW,
                              double naturalH) {
  if (sizeW > 0.0 && sizeH > 0.0) return CGSizeMake(sizeW, sizeH);
  if (naturalW <= 0.0 || naturalH <= 0.0) return CGSizeMake(sizeW, sizeH);
  if (sizeW > 0.0) {
    const double scale = sizeW / naturalW;
    return CGSizeMake(sizeW, naturalH * scale);
  }
  if (sizeH > 0.0) {
    const double scale = sizeH / naturalH;
    return CGSizeMake(naturalW * scale, sizeH);
  }
  return CGSizeMake(0, 0);
}

double clampOpacity(double opacity) {
  if (!(opacity >= 0.0)) return 0.0;
  if (opacity > 1.0) return 1.0;
  return opacity;
}

double clampUnit(double v) {
  if (!(v >= 0.0)) return 0.0;
  if (v > 1.0) return 1.0;
  return v;
}

int hexDigit(unichar c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
  if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
  return -1;
}

// Parse a color string in hex (#rgb / #rgba / #rrggbb / #rrggbbaa) or CSS
// rgb()/rgba() form into 0..1 RGBA components. Returns NO on any malformed
// input; callers surface that as InvalidSpec. Whitespace is tolerated inside
// the rgb(...) form; alpha defaults to 1.0 when omitted (both the three-digit
// hex and the rgb() form).
BOOL parseColorString(NSString *input, double *outR, double *outG,
                      double *outB, double *outA) {
  if (input.length == 0) return NO;
  NSString *s = [[input stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]]
      lowercaseString];
  if (s.length == 0) return NO;

  if ([s hasPrefix:@"#"]) {
    NSString *body = [s substringFromIndex:1];
    const NSUInteger len = body.length;
    if (len != 3 && len != 4 && len != 6 && len != 8) return NO;
    int digits[8] = {0};
    for (NSUInteger i = 0; i < len; i++) {
      const int d = hexDigit([body characterAtIndex:i]);
      if (d < 0) return NO;
      digits[i] = d;
    }
    double r = 0, g = 0, b = 0, a = 1.0;
    if (len == 3 || len == 4) {
      r = (digits[0] * 16 + digits[0]) / 255.0;
      g = (digits[1] * 16 + digits[1]) / 255.0;
      b = (digits[2] * 16 + digits[2]) / 255.0;
      if (len == 4) a = (digits[3] * 16 + digits[3]) / 255.0;
    } else {
      r = (digits[0] * 16 + digits[1]) / 255.0;
      g = (digits[2] * 16 + digits[3]) / 255.0;
      b = (digits[4] * 16 + digits[5]) / 255.0;
      if (len == 8) a = (digits[6] * 16 + digits[7]) / 255.0;
    }
    *outR = clampUnit(r);
    *outG = clampUnit(g);
    *outB = clampUnit(b);
    *outA = clampUnit(a);
    return YES;
  }

  if ([s hasPrefix:@"rgb"]) {
    const NSUInteger open = [s rangeOfString:@"("].location;
    const NSUInteger close = [s rangeOfString:@")"].location;
    if (open == NSNotFound || close == NSNotFound || close <= open + 1) {
      return NO;
    }
    NSString *inner = [s substringWithRange:NSMakeRange(open + 1,
                                                         close - open - 1)];
    NSArray<NSString *> *parts = [inner componentsSeparatedByString:@","];
    if (parts.count != 3 && parts.count != 4) return NO;
    double vals[4] = {0, 0, 0, 1.0};
    for (NSUInteger i = 0; i < parts.count; i++) {
      NSString *raw = [parts[i]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if (raw.length == 0) return NO;
      vals[i] = raw.doubleValue;
    }
    // r/g/b in 0..255 → 0..1; alpha already in 0..1.
    *outR = clampUnit(vals[0] / 255.0);
    *outG = clampUnit(vals[1] / 255.0);
    *outB = clampUnit(vals[2] / 255.0);
    *outA = clampUnit(vals[3]);
    return YES;
  }

  return NO;
}

// Pre-rasterize a text overlay into a CIImage. CoreText drives both the
// measurement and the drawing (matches docs/api.md "native font rendering"):
// CTFramesetter measures the text extent so the bitmap matches the glyph
// advance, then CTFrameDraw rasterizes into a CGBitmapContext. Shadow, when
// present, adds padding around the measured extent so a large blur radius
// doesn't clip. CoreText (not CATextLayer) is used deliberately so the
// rasterization is coordinate-system-uniform across iOS and macOS — see the
// render block below and issue #65.
CIImage *rasterizeTextOverlay(RNVPTextOverlay *overlay,
                              NSError *_Nullable __autoreleasing *error) {
  // --- Color parsing ------------------------------------------------------
  double cr = 0, cg = 0, cb = 0, ca = 1.0;
  if (!parseColorString(overlay.colorString, &cr, &cg, &cb, &ca)) {
    if (error) {
      *error = makeError(
          RNVPOverlayRendererErrorCodeInvalidSpec,
          [NSString stringWithFormat:
                        @"text overlay color is malformed: %@",
                        overlay.colorString ?: @"(nil)"]);
    }
    return nil;
  }

  // --- Font ---------------------------------------------------------------
  const CGFloat fontSize = overlay.fontSize > 0.0 ? overlay.fontSize : 16.0;
  CTFontRef baseFont = NULL;
  if (overlay.fontFamily.length > 0) {
    baseFont = CTFontCreateWithName(
        (__bridge CFStringRef)overlay.fontFamily, fontSize, NULL);
  }
  if (baseFont == NULL) {
    baseFont =
        CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, fontSize, NULL);
  }
  CTFontRef font = baseFont;
  if (overlay.weightBold) {
    CTFontRef bolded = CTFontCreateCopyWithSymbolicTraits(
        baseFont, fontSize, NULL, kCTFontTraitBold, kCTFontTraitBold);
    if (bolded != NULL) {
      CFRelease(baseFont);
      font = bolded;
    }
  }

  // --- Attributed string for measurement ---------------------------------
  // Paragraph alignment goes into the attributed string so both CTFramesetter
  // (bounds) and CTFrameDraw (multi-line layout) honour it.
  CTTextAlignment ctAlignment = kCTTextAlignmentLeft;
  if (overlay.alignment == RNVPTextAlignmentCenter) {
    ctAlignment = kCTTextAlignmentCenter;
  } else if (overlay.alignment == RNVPTextAlignmentRight) {
    ctAlignment = kCTTextAlignmentRight;
  }
  CTParagraphStyleSetting paragraphSettings[] = {
      {kCTParagraphStyleSpecifierAlignment, sizeof(CTTextAlignment),
       &ctAlignment},
  };
  CTParagraphStyleRef paragraph =
      CTParagraphStyleCreate(paragraphSettings, 1);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  const CGFloat colorComps[4] = {(CGFloat)cr, (CGFloat)cg, (CGFloat)cb,
                                  (CGFloat)ca};
  CGColorRef cgColor = CGColorCreate(cs, colorComps);
  NSDictionary *attrs = @{
    (id)kCTFontAttributeName : (__bridge id)font,
    (id)kCTForegroundColorAttributeName : (__bridge id)cgColor,
    (id)kCTParagraphStyleAttributeName : (__bridge id)paragraph,
  };
  NSAttributedString *attr =
      [[NSAttributedString alloc] initWithString:(overlay.text ?: @"")
                                      attributes:attrs];

  // --- Measure ------------------------------------------------------------
  CTFramesetterRef framesetter =
      CTFramesetterCreateWithAttributedString((CFAttributedStringRef)attr);
  CFRange fitRange = CFRangeMake(0, (CFIndex)attr.length);
  const CGSize constrain = CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX);
  CGSize measured = CTFramesetterSuggestFrameSizeWithConstraints(
      framesetter, fitRange, NULL, constrain, NULL);

  // Pad for the shadow so a large blur doesn't clip at the bitmap edge. The
  // padding is symmetric in X/Y so anchor math stays a plain rect — the
  // drawn glyphs sit roughly in the center of the bitmap.
  CGFloat padX = 2.0;
  CGFloat padY = 2.0;
  if (overlay.hasShadow) {
    padX += std::fabs(overlay.shadowDx) + std::fabs(overlay.shadowBlur);
    padY += std::fabs(overlay.shadowDy) + std::fabs(overlay.shadowBlur);
  }
  const size_t W = (size_t)std::ceil(measured.width + 2.0 * padX);
  const size_t H = (size_t)std::ceil(measured.height + 2.0 * padY);
  if (W == 0 || H == 0) {
    if (error) {
      *error = makeError(
          RNVPOverlayRendererErrorCodeTextRasterFailed,
          [NSString stringWithFormat:
                        @"text overlay measured as zero-area (text=%@, "
                        @"fontSize=%g)",
                        overlay.text ?: @"(nil)", overlay.fontSize]);
    }
    CFRelease(framesetter);
    CFRelease(paragraph);
    CGColorRelease(cgColor);
    CGColorSpaceRelease(cs);
    CFRelease(font);
    return nil;
  }

  // --- Bitmap + CoreText render -------------------------------------------
  // Draw the glyphs with CoreText straight into the bitmap context instead of
  // via CATextLayer's -renderInContext:. CATextLayer inherits Core Animation's
  // *platform-dependent* layer coordinate system — top-left origin on iOS,
  // bottom-left on macOS (Apple's Core Animation Programming Guide, "the
  // default coordinate system differs between iOS and macOS"). With the same
  // bottom-left-origin CGBitmapContext that meant the text rasterized upright
  // on the macOS test host but upside-down on device/simulator, which is
  // issue #65. CoreText drawing is governed solely by the CGContext's CTM,
  // identical on every platform, so the output is uniform and the host XCTest
  // is authoritative for the shipping iOS path. The image-overlay path was
  // never affected because it loads CGImages via ImageIO (also platform-
  // uniform), not via a CALayer.
  CGBitmapInfo bitmapInfo = (CGBitmapInfo)(kCGImageAlphaPremultipliedLast) |
                             kCGBitmapByteOrder32Big;
  CGContextRef ctx =
      CGBitmapContextCreate(NULL, W, H, 8, W * 4, cs, bitmapInfo);
  if (ctx == NULL) {
    if (error) {
      *error = makeError(RNVPOverlayRendererErrorCodeTextRasterFailed,
                         @"CGBitmapContextCreate returned NULL for text "
                         @"overlay rasterization.");
    }
    CFRelease(framesetter);
    CFRelease(paragraph);
    CGColorRelease(cgColor);
    CGColorSpaceRelease(cs);
    CFRelease(font);
    return nil;
  }

  if (overlay.hasShadow) {
    double sr = 0, sg = 0, sb = 0, sa = 1.0;
    if (overlay.shadowColorString.length > 0) {
      parseColorString(overlay.shadowColorString, &sr, &sg, &sb, &sa);
    }
    const CGFloat shadowComps[4] = {(CGFloat)sr, (CGFloat)sg, (CGFloat)sb,
                                     (CGFloat)sa};
    CGColorRef shadowCGColor = CGColorCreate(cs, shadowComps);
    // The public shadow dy is "positive = downward" (screen convention); the
    // bitmap context is bottom-left-origin (y up), so negate dy to keep the
    // shadow falling in the expected direction.
    CGContextSetShadowWithColor(
        ctx, CGSizeMake(overlay.shadowDx, -overlay.shadowDy),
        overlay.shadowBlur, shadowCGColor);
    CGColorRelease(shadowCGColor);
  }

  // Lay the measured text into a rect inset by the edge/shadow padding so a
  // descender or large blur doesn't clip at the bitmap border. CoreText fills
  // the rect from its top line downward; in the y-up bitmap the cap of the
  // glyphs lands at high y → low memory rows → the top of the resulting
  // CGImage, i.e. upright, matching the row order ImageIO hands the image
  // overlay path. No CTM flip is needed (and adding one would invert it).
  CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
  const CGRect textRect =
      CGRectMake(padX, padY, measured.width, measured.height);
  CGPathRef textPath = CGPathCreateWithRect(textRect, NULL);
  CTFrameRef frame =
      CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), textPath, NULL);
  CTFrameDraw(frame, ctx);
  CFRelease(frame);
  CGPathRelease(textPath);

  CGImageRef cgImage = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  CFRelease(framesetter);
  CFRelease(paragraph);
  CGColorRelease(cgColor);
  CGColorSpaceRelease(cs);
  CFRelease(font);

  if (cgImage == NULL) {
    if (error) {
      *error = makeError(RNVPOverlayRendererErrorCodeTextRasterFailed,
                         @"CGBitmapContextCreateImage returned NULL for "
                         @"text overlay rasterization.");
    }
    return nil;
  }
  CIImage *result = [CIImage imageWithCGImage:cgImage];
  CGImageRelease(cgImage);
  return result;
}

} // namespace

@implementation RNVPImageOverlay

- (instancetype)initWithImageURL:(NSURL *)imageURL
                         anchorX:(double)anchorX
                         anchorY:(double)anchorY
                        hasSizeW:(BOOL)hasSizeW
                    sizeWIsRatio:(BOOL)sizeWIsRatio
                      sizeWValue:(double)sizeWValue
                        hasSizeH:(BOOL)hasSizeH
                    sizeHIsRatio:(BOOL)sizeHIsRatio
                      sizeHValue:(double)sizeHValue
                         opacity:(double)opacity
                    hasTimeRange:(BOOL)hasTimeRange
                        startSec:(double)startSec
                          endSec:(double)endSec {
  if ((self = [super init])) {
    _imageURL = imageURL;
    _anchorX = anchorX;
    _anchorY = anchorY;
    _hasSizeW = hasSizeW;
    _sizeWIsRatio = sizeWIsRatio;
    _sizeWValue = sizeWValue;
    _hasSizeH = hasSizeH;
    _sizeHIsRatio = sizeHIsRatio;
    _sizeHValue = sizeHValue;
    _opacity = opacity;
    _hasTimeRange = hasTimeRange;
    _startSec = startSec;
    _endSec = endSec;
  }
  return self;
}

@end

@implementation RNVPTextOverlay

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
                      endSec:(double)endSec {
  if ((self = [super init])) {
    _text = [text copy];
    _fontFamily = [fontFamily copy];
    _fontSize = fontSize;
    _colorString = [colorString copy];
    _weightBold = weightBold;
    _alignment = alignment;
    _hasShadow = hasShadow;
    _shadowColorString = [shadowColorString copy];
    _shadowBlur = shadowBlur;
    _shadowDx = shadowDx;
    _shadowDy = shadowDy;
    _anchorX = anchorX;
    _anchorY = anchorY;
    _hasTimeRange = hasTimeRange;
    _startSec = startSec;
    _endSec = endSec;
  }
  return self;
}

@end

namespace {

// One prepared overlay ready to composite. `prepared` is already scaled,
// opacified and translated to its on-frame position; `hasTimeRange`/
// `startSec`/`endSec` mirror the caller's spec so the per-frame check stays
// branchless.
struct PreparedOverlay {
  CIImage *prepared;
  bool hasTimeRange;
  double startSec;
  double endSec;
};

bool overlayActive(const PreparedOverlay &o, double timeSec) {
  if (!o.hasTimeRange) return true;
  return timeSec + 1e-6 >= o.startSec && timeSec < o.endSec + 1e-6;
}

// Translate @p overlayImage (already scaled to its output-pixel size and
// opacified/styled) so it lands at the anchor position on a @p targetSize
// frame. Returns the translated CIImage. Y-flip logic matches the header's
// coordinate convention.
CIImage *positionAtAnchor(CIImage *overlayImage, double anchorX,
                          double anchorY, CGSize targetSize) {
  const CGRect extent = overlayImage.extent;
  const double overlayW = extent.size.width;
  const double overlayH = extent.size.height;
  const double outputW = targetSize.width;
  const double outputH = targetSize.height;
  const double screenX = anchorX * (outputW - overlayW);
  const double screenY = anchorY * (outputH - overlayH);
  const double ciX = screenX - extent.origin.x;
  const double ciY = (outputH - overlayH - screenY) - extent.origin.y;
  return [overlayImage imageByApplyingTransform:
                           CGAffineTransformMakeTranslation(ciX, ciY)];
}

} // namespace

@implementation RNVPOverlayRenderer {
  std::vector<PreparedOverlay> _prepared;
}

- (nullable instancetype)initWithOverlays:(NSArray *)overlays
                               targetSize:(CGSize)targetSize
                                    error:(NSError *_Nullable __autoreleasing *)error {
  if ((self = [super init])) {
    _prepared.reserve(overlays.count);
    for (NSUInteger i = 0; i < overlays.count; ++i) {
      id entry = overlays[i];

      if ([entry isKindOfClass:[RNVPImageOverlay class]]) {
        RNVPImageOverlay *overlay = (RNVPImageOverlay *)entry;
        // Resolve unit-tagged dims against the output canvas. Ratio
        // values multiply the corresponding canvas axis; px values are
        // already in output pixels.
        const double sizeW = overlay.hasSizeW
            ? (overlay.sizeWIsRatio
                   ? overlay.sizeWValue * targetSize.width
                   : overlay.sizeWValue)
            : 0.0;
        const double sizeH = overlay.hasSizeH
            ? (overlay.sizeHIsRatio
                   ? overlay.sizeHValue * targetSize.height
                   : overlay.sizeHValue)
            : 0.0;
        if (!(sizeW > 0.0) && !(sizeH > 0.0)) {
          if (error) {
            *error = makeError(
                RNVPOverlayRendererErrorCodeInvalidSpec,
                [NSString stringWithFormat:
                              @"overlay[%lu].size requires at least one of "
                              @"{width, height} > 0",
                              (unsigned long)i]);
          }
          return nil;
        }

        CIImage *raw = loadImage(overlay.imageURL);
        if (raw == nil) {
          if (error) {
            *error = makeError(
                RNVPOverlayRendererErrorCodeImageLoadFailed,
                [NSString stringWithFormat:
                              @"overlay[%lu] image failed to load from %@",
                              (unsigned long)i, overlay.imageURL.path]);
          }
          return nil;
        }

        const CGRect naturalExtent = raw.extent;
        const CGSize scaled = resolveTargetImageSize(
            sizeW, sizeH, naturalExtent.size.width,
            naturalExtent.size.height);
        if (!(scaled.width > 0.0) || !(scaled.height > 0.0)) {
          if (error) {
            *error = makeError(
                RNVPOverlayRendererErrorCodeInvalidSpec,
                [NSString stringWithFormat:
                              @"overlay[%lu] resolved to a zero-area size "
                              @"(source %gx%g, requested %g×%g)",
                              (unsigned long)i, naturalExtent.size.width,
                              naturalExtent.size.height, sizeW, sizeH]);
          }
          return nil;
        }

        const double sx = scaled.width / naturalExtent.size.width;
        const double sy = scaled.height / naturalExtent.size.height;
        CIImage *prepared = [raw
            imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];

        const double op = clampOpacity(overlay.opacity);
        if (op < 1.0 - 1e-6) {
          prepared = [prepared
              imageByApplyingFilter:@"CIColorMatrix"
                withInputParameters:@{
                  @"inputRVector" : [CIVector vectorWithX:1 Y:0 Z:0 W:0],
                  @"inputGVector" : [CIVector vectorWithX:0 Y:1 Z:0 W:0],
                  @"inputBVector" : [CIVector vectorWithX:0 Y:0 Z:1 W:0],
                  @"inputAVector" :
                      [CIVector vectorWithX:0 Y:0 Z:0 W:op],
                  @"inputBiasVector" :
                      [CIVector vectorWithX:0 Y:0 Z:0 W:0],
                }];
        }

        prepared = positionAtAnchor(prepared, overlay.anchorX,
                                    overlay.anchorY, targetSize);

        PreparedOverlay stored;
        stored.prepared = prepared;
        stored.hasTimeRange = overlay.hasTimeRange ? true : false;
        stored.startSec = overlay.startSec;
        stored.endSec = overlay.endSec;
        _prepared.push_back(stored);
        continue;
      }

      if ([entry isKindOfClass:[RNVPTextOverlay class]]) {
        RNVPTextOverlay *overlay = (RNVPTextOverlay *)entry;
        if (overlay.text.length == 0) {
          if (error) {
            *error = makeError(
                RNVPOverlayRendererErrorCodeInvalidSpec,
                [NSString stringWithFormat:
                              @"overlay[%lu].text must be a non-empty "
                              @"string",
                              (unsigned long)i]);
          }
          return nil;
        }
        if (!(overlay.fontSize > 0.0)) {
          if (error) {
            *error = makeError(
                RNVPOverlayRendererErrorCodeInvalidSpec,
                [NSString stringWithFormat:
                              @"overlay[%lu].fontSize must be > 0 (got %g)",
                              (unsigned long)i, overlay.fontSize]);
          }
          return nil;
        }

        NSError *rasterErr = nil;
        CIImage *rasterized = rasterizeTextOverlay(overlay, &rasterErr);
        if (rasterized == nil) {
          if (error) *error = rasterErr;
          return nil;
        }
        rasterized = positionAtAnchor(rasterized, overlay.anchorX,
                                      overlay.anchorY, targetSize);

        PreparedOverlay stored;
        stored.prepared = rasterized;
        stored.hasTimeRange = overlay.hasTimeRange ? true : false;
        stored.startSec = overlay.startSec;
        stored.endSec = overlay.endSec;
        _prepared.push_back(stored);
        continue;
      }

      if (error) {
        *error = makeError(
            RNVPOverlayRendererErrorCodeInvalidSpec,
            [NSString stringWithFormat:
                          @"overlay[%lu] has unsupported class %@; expected "
                          @"RNVPImageOverlay or RNVPTextOverlay",
                          (unsigned long)i, NSStringFromClass([entry class])]);
      }
      return nil;
    }
  }
  return self;
}

- (BOOL)hasActiveOverlaysAtTimeSec:(double)timeSec {
  for (const auto &o : _prepared) {
    if (overlayActive(o, timeSec)) return YES;
  }
  return NO;
}

- (CIImage *)applyToFrame:(CIImage *)frame atTimeSec:(double)timeSec {
  CIImage *result = frame;
  for (const auto &o : _prepared) {
    if (!overlayActive(o, timeSec)) continue;
    result = [o.prepared
        imageByApplyingFilter:@"CISourceOverCompositing"
          withInputParameters:@{@"inputBackgroundImage" : result}];
  }
  return result;
}

@end
