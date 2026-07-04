import { drawWithFloat16 } from '../src/drawWithFloat16';
import type {
  FrameDrawerContext,
  FrameTarget,
  PixelFormat,
} from '../src/nitro/VideoPipeline.nitro';

function makeTarget(format: PixelFormat, w: number, h: number): FrameTarget {
  return {
    unstable_bufferAddr: 0n,
    width: w,
    height: h,
    format,
    writeBytes: jest.fn(),
    unstable_blitFromNativeTexture: jest.fn(),
  };
}

function makeCtx(w: number, h: number, format: PixelFormat): FrameDrawerContext {
  return {
    frameIndex: 0,
    timeSec: 0,
    elapsedMs: 0,
    width: w,
    height: h,
    target: makeTarget(format, w, h),
  } as FrameDrawerContext;
}

/** Decode the ArrayBuffer the helper handed to writeBytes as half-floats. */
function decodeHalves(target: FrameTarget): Float16Array {
  const write = target.writeBytes as unknown as jest.Mock;
  const ab = write.mock.calls[0]?.[0] as ArrayBuffer;
  return new Float16Array(ab);
}

describe('drawWithFloat16', () => {
  it('requires an rgbaFp16 target — throws (before writing) on 8-bit targets', () => {
    for (const fmt of ['bgra8888', 'rgba8888'] as const) {
      const ctx = makeCtx(4, 4, fmt);
      expect(() => drawWithFloat16(() => {})(ctx)).toThrow(/rgbaFp16.*HDR|8-bit/);
      expect(ctx.target.writeBytes as unknown as jest.Mock).not.toHaveBeenCalled();
    }
  });

  it('writes width*height*8 bytes (4 half-floats per pixel) to an rgbaFp16 target', () => {
    const ctx = makeCtx(5, 3, 'rgbaFp16');
    drawWithFloat16((pixels) => {
      pixels.fill(1.0);
    })(ctx);
    const write = ctx.target.writeBytes as unknown as jest.Mock;
    expect(write).toHaveBeenCalledTimes(1);
    expect((write.mock.calls[0]?.[0] as ArrayBuffer).byteLength).toBe(5 * 3 * 4 * 2);
  });

  it('preserves RGBA channel order (no swizzle) and premultiplied alpha', () => {
    const ctx = makeCtx(1, 1, 'rgbaFp16');
    drawWithFloat16((pixels) => {
      pixels[0] = 0.25; // R
      pixels[1] = 0.5; // G
      pixels[2] = 0.75; // B
      pixels[3] = 1.0; // A
    })(ctx);
    const halves = decodeHalves(ctx.target);
    expect(Array.from(halves)).toEqual([0.25, 0.5, 0.75, 1.0]); // exact in f16
  });

  it('preserves HDR highlights above SDR white (> 1.0) — the point of the format', () => {
    const ctx = makeCtx(1, 1, 'rgbaFp16');
    drawWithFloat16((pixels) => {
      pixels[0] = 8.0; // far above 1.0
      pixels[1] = 2.5;
      pixels[2] = 1.0;
      pixels[3] = 1.0;
    })(ctx);
    const halves = decodeHalves(ctx.target);
    expect(halves[0]).toBeCloseTo(8.0, 5);
    expect(halves[1]).toBeCloseTo(2.5, 5);
    expect(halves[0] as number).toBeGreaterThan(1.0);
  });

  // The inlined float32→float16 encoder must match the platform reference
  // (`Math.f16round`) across every regime, or HDR values would corrupt.
  it('matches Math.f16round for representative + edge values', () => {
    const values = [
      0,
      -0,
      1,
      -1,
      0.5,
      0.25,
      2.5,
      8,
      100,
      1000,
      65504, // max half
      65505,
      70000, // overflow → Infinity
      6.103515625e-5, // smallest normal half
      6e-8, // subnormal
      1e-10, // underflow → 0
      Math.PI,
      -Math.PI,
      0.1,
      0.2,
      123.456,
      Number.POSITIVE_INFINITY,
      Number.NEGATIVE_INFINITY,
    ];
    const ctx = makeCtx(values.length, 1, 'rgbaFp16');
    drawWithFloat16((pixels) => {
      // width*height*4 channels; pack the test values into the first slots.
      for (let i = 0; i < values.length; i++) pixels[i] = values[i] as number;
    })(ctx);
    const halves = decodeHalves(ctx.target);
    for (let i = 0; i < values.length; i++) {
      const expected = Math.f16round(values[i] as number);
      const got = halves[i] as number;
      if (Number.isNaN(expected)) {
        expect(Number.isNaN(got)).toBe(true);
      } else {
        expect(got).toBe(expected);
      }
    }
  });

  it('matches Math.f16round across a large deterministic random sample', () => {
    // Deterministic LCG (no Math.random) so the test is reproducible.
    let seed = 0x12345678;
    const next = () => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    };
    const N = 4096;
    const inputs = new Float32Array(N);
    for (let i = 0; i < N; i++) {
      // Spread across magnitudes incl. HDR range and negatives.
      const mag = (next() - 0.4) * 2000;
      inputs[i] = mag * next();
    }
    const ctx = makeCtx(N, 1, 'rgbaFp16');
    drawWithFloat16((pixels) => {
      pixels.set(inputs.subarray(0, pixels.length > N ? N : pixels.length));
    })(ctx);
    const halves = decodeHalves(ctx.target);
    for (let i = 0; i < N; i++) {
      expect(halves[i]).toBe(Math.f16round(inputs[i] as number));
    }
  });
});
