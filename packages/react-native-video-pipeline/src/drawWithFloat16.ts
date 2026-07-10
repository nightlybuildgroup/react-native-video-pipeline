import type { FrameDrawer, FrameDrawerContext } from './nitro/VideoPipeline.nitro';

/**
 * Callback signature for `drawWithFloat16`: fills a pre-allocated `Float32Array`
 * of length `ctx.width * ctx.height * 4` with **half-float RGBA** pixels, in
 * `R, G, B, A` order (no BGRA swizzle — the `rgbaFp16` buffer is RGBA-ordered).
 *
 * Color space / range contract (see `PixelFormat` `'rgbaFp16'`, #99):
 * - **Linear Rec.2020**, **premultiplied** alpha, **extended range** — channel
 *   values may exceed `1.0` for highlights above SDR white (that headroom is
 *   the entire point of HDR compose). Values are stored as IEEE half-floats, so
 *   the representable range is roughly `±65504`.
 * - You write `Float32Array` for convenience; the helper converts each channel
 *   to a half-float before handing the buffer to the encoder. Producing the
 *   correct *linear Rec.2020* values is the caller's responsibility — the helper
 *   only transports bytes, it does not color-manage.
 */
export type Float16Drawer = (pixels: Float32Array, ctx: FrameDrawerContext) => void;

/**
 * The half-float (`rgbaFp16`) counterpart to {@link drawWithRGBA} — the
 * ergonomic CPU worklet path for **HDR compose** (`output.colorRange: 'hdr'`,
 * #99). Your drawer fills a `Float32Array` of `width * height * 4` linear
 * Rec.2020 RGBA channels; the helper converts them to IEEE half-floats and
 * `writeBytes`es the `width * height * 8`-byte buffer the encoder appends.
 *
 * ```ts
 * import { Video, drawWithFloat16 } from 'react-native-video-pipeline';
 *
 * // iOS worklet-generated HDR (v0.5.0). Source-clip Video.compose HDR and all
 * // of Android are not yet supported — see output.colorRange.
 * await Video.synthesize({
 *   output: { path, width, height, fps, colorRange: 'hdr' },
 *   duration: { mode: 'fixed', seconds: 1 },
 *   drawFrame: drawWithFloat16((pixels, ctx) => {
 *     'worklet';
 *     const i = (y * ctx.width + x) * 4;
 *     pixels[i]     = 2.5; // R — an HDR highlight above SDR white (1.0)
 *     pixels[i + 1] = 1.0; // G
 *     pixels[i + 2] = 1.0; // B
 *     pixels[i + 3] = 1.0; // A (premultiplied)
 *   }),
 * });
 * ```
 *
 * It **requires an `rgbaFp16` target** and throws on an 8-bit one — the inverse
 * of `drawWithRGBA`, which throws on `rgbaFp16`. An `rgbaFp16` target only
 * appears under `output.colorRange: 'hdr'`.
 *
 * The float32→float16 conversion is round-to-nearest-even and is **inlined**
 * here rather than factored into a helper call: a worklet cannot call a plain
 * (non-worklet) function on the UI runtime, and calling a sibling module-scope
 * worklet breaks when this package is consumed pre-built (#75). Correctness is
 * covered end-to-end by `__tests__/drawWithFloat16.test.ts`, which compares the
 * emitted halves against `Math.f16round` across normals, subnormals,
 * highlights, and specials.
 */
export function drawWithFloat16(draw: Float16Drawer): FrameDrawer {
  return (ctx: FrameDrawerContext): void => {
    'worklet';
    const { width, height, target } = ctx;
    if (target.format !== 'rgbaFp16') {
      throw new Error(
        `drawWithFloat16 requires an 'rgbaFp16' (HDR) target, but this frame's ` +
          `target is '${target.format}'. Use drawWithRGBA for 8-bit targets, or ` +
          "set output.colorRange: 'hdr' on Video.synthesize to get an FP16 target.",
      );
    }
    const count = width * height * 4;
    const pixels = new Float32Array(count);
    draw(pixels, ctx);

    // Convert linear-RGBA float32 → IEEE half-float (round to nearest even).
    // Inlined (no function calls) so it stays worklet-safe on the UI runtime.
    const out = new Uint16Array(count);
    const scratchF32 = new Float32Array(1);
    const scratchU32 = new Uint32Array(scratchF32.buffer);
    for (let i = 0; i < count; i++) {
      scratchF32[0] = pixels[i] ?? 0;
      const x = scratchU32[0] ?? 0;
      const sign = (x >>> 16) & 0x8000;
      const exp = (x >>> 23) & 0xff;
      let mant = x & 0x7fffff;
      let half: number;
      if (exp === 0xff) {
        // Inf (mant 0) or NaN (mant != 0).
        half = sign | 0x7c00 | (mant !== 0 ? 0x0200 : 0);
      } else {
        // Rebias exponent: f32 bias 127 → f16 bias 15, i.e. exp - 127 + 15.
        let e = exp - 112;
        if (e >= 0x1f) {
          half = sign | 0x7c00; // overflow → Inf
        } else if (e <= 0) {
          if (e < -10) {
            half = sign; // too small even for a subnormal → signed zero
          } else {
            mant |= 0x800000; // restore the implicit leading 1
            const shift = 14 - e; // 14..24
            const roundBit = 1 << (shift - 1);
            let m = mant >>> shift;
            const rem = mant & ((roundBit << 1) - 1);
            if (rem > roundBit || (rem === roundBit && (m & 1) === 1)) m += 1;
            half = sign | m; // m may reach 0x400 = smallest normal — correct
          }
        } else {
          let m = mant >>> 13;
          const rem = mant & 0x1fff;
          if (rem > 0x1000 || (rem === 0x1000 && (m & 1) === 1)) {
            m += 1;
            if (m === 0x400) {
              m = 0;
              e += 1; // mantissa carry bumps the exponent
            }
          }
          half = e >= 0x1f ? sign | 0x7c00 : sign | (e << 10) | m;
        }
      }
      out[i] = half;
    }

    // `Uint16Array` stores each half-word in native endianness; the native
    // FP16 consumers (iOS `kCVPixelFormatType_64RGBAHalf` CVPixelBuffer,
    // Android AHardwareBuffer) are little-endian on every supported device, so
    // the raw bytes line up without a swap. `writeBytes` memcpys them as-is.
    target.writeBytes(out.buffer);
  };
}
