import type { FrameDrawer, FrameDrawerContext } from './nitro/VideoPipeline.nitro';

/**
 * Callback signature for `drawWithRGBA`: fills a pre-allocated `Uint8Array`
 * of length `ctx.width * ctx.height * 4` with **premultiplied RGBA** pixels.
 *
 * Byte order is always R, G, B, A regardless of the native platform's
 * underlying pixel format — the helper swizzles to BGRA on iOS internally.
 *
 * Alpha convention: **premultiplied**. Matches Skia's default and Apple's
 * native CVPixelBuffer convention. If you need straight-alpha semantics,
 * premultiply before writing (`r *= a/255`, etc.).
 *
 * Alpha semantics at the encoder:
 * - `Video.synthesize` (null-input) → output is H.264, which has no alpha
 *   channel. Whatever alpha you write is discarded by the encoder. Write
 *   `a = 255` unless you have a specific reason not to.
 * - `Video.compose` over a source clip → the buffer you fill becomes the
 *   output frame as-is; `drawWithRGBA` does NOT alpha-composite it over the
 *   source. The source frame is available read-only via `ctx.source`, so you
 *   can sample and blend it yourself. For automatic source compositing use
 *   `drawWithSkia`, which pre-draws the source frame into the canvas before
 *   your worklet runs.
 */
export type RGBADrawer = (pixels: Uint8Array, ctx: FrameDrawerContext) => void;

/**
 * Wrap a plain-pixel `RGBADrawer` into a `FrameDrawer` that the native
 * compose pump can invoke. The helper hides the `FrameTarget.writeBytes`
 * boilerplate — and, on iOS, the BGRA byte-order swizzle — so consumer
 * worklets stay on the straightforward "write pixels, return" model.
 *
 * Usage:
 * ```ts
 * import { Video, drawWithRGBA } from 'react-native-video-pipeline';
 *
 * await Video.synthesize({
 *   output: { path, width: 320, height: 240, fps: 30 },
 *   duration: { mode: 'fixed', seconds: 3 },
 *   drawFrame: drawWithRGBA((pixels, ctx) => {
 *     'worklet';
 *     for (let y = 0; y < ctx.height; y++) {
 *       for (let x = 0; x < ctx.width; x++) {
 *         const i = (y * ctx.width + x) * 4;
 *         pixels[i]     = 255; // R
 *         pixels[i + 1] = 0;   // G
 *         pixels[i + 2] = 0;   // B
 *         pixels[i + 3] = 255; // A
 *       }
 *     }
 *   }),
 * });
 * ```
 *
 * Performance notes:
 * - The helper allocates a fresh `Uint8Array(w * h * 4)` per frame. The
 *   allocation is cheap at typical synthesize sizes (e.g. 320×240 → 300 KB)
 *   and the per-frame overhead is dominated by H.264 encoding, not by
 *   the allocator. Pools are a premature optimisation.
 * - On iOS the helper does a byte-order swap (RGBA → BGRA) because the
 *   native CVPixelBuffer is `kCVPixelFormatType_32BGRA`. The swap is one
 *   SIMD-friendly pass over the buffer — cost is lost in the encoder.
 * - On Android the native buffer format is RGBA (matches the helper's
 *   public contract), so the memcpy is direct with no swizzle.
 *
 * For consumers using Skia, `drawWithSkia` (from the sibling package
 * `react-native-video-pipeline-skia`) is the preferred path — it can reach
 * zero-copy on iOS via the `MTLBlitCommandEncoder` fast path, whereas this
 * helper always pays one CPU copy. Use `drawWithRGBA` when you are
 * computing pixels directly in JS and do not want a Skia dependency.
 */
export function drawWithRGBA(draw: RGBADrawer): FrameDrawer {
  return (ctx: FrameDrawerContext): void => {
    'worklet';
    const { width, height, target } = ctx;
    if (target.format === 'rgbaFp16') {
      // `drawWithRGBA` is an 8-bit (Uint8Array) helper; it cannot fill a
      // half-float HDR target (#99). This only happens under
      // `output.colorRange: 'hdr'`.
      throw new Error(
        "drawWithRGBA is 8-bit-only and cannot target an 'rgbaFp16' (HDR) " +
          "buffer. For output.colorRange: 'hdr', write half-float pixels via " +
          'target.writeBytes directly (Float16, width*height*4 channels), or ' +
          'draw through an F16 Skia surface with drawWithSkia.',
      );
    }
    const length = width * height * 4;
    const pixels = new Uint8Array(length);
    draw(pixels, ctx);

    if (target.format === 'bgra8888') {
      // In-place RGBA → BGRA swap. Alpha stays put; R and B swap.
      for (let i = 0; i < length; i += 4) {
        const r = pixels[i] ?? 0;
        pixels[i] = pixels[i + 2] ?? 0;
        pixels[i + 2] = r;
      }
    }
    // else target.format === 'rgba8888' — bytes already match native layout.

    target.writeBytes(pixels.buffer);
  };
}
