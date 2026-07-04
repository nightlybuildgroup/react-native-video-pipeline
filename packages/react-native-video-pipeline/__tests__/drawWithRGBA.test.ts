import { drawWithRGBA } from '../src/drawWithRGBA';
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

describe('drawWithRGBA', () => {
  it('fills an 8-bit RGBA buffer and writes it to an rgba8888 target', () => {
    const ctx = makeCtx(4, 2, 'rgba8888');
    drawWithRGBA((pixels) => {
      pixels[0] = 1;
      pixels[3] = 255;
    })(ctx);
    const write = ctx.target.writeBytes as unknown as jest.Mock;
    expect(write).toHaveBeenCalledTimes(1);
    expect((write.mock.calls[0]?.[0] as ArrayBuffer).byteLength).toBe(4 * 2 * 4);
  });

  it('swizzles RGBA→BGRA for a bgra8888 target', () => {
    const ctx = makeCtx(1, 1, 'bgra8888');
    drawWithRGBA((pixels) => {
      pixels[0] = 10; // R
      pixels[1] = 20; // G
      pixels[2] = 30; // B
      pixels[3] = 40; // A
    })(ctx);
    const write = ctx.target.writeBytes as unknown as jest.Mock;
    const out = new Uint8Array(write.mock.calls[0]?.[0] as ArrayBuffer);
    expect(Array.from(out)).toEqual([30, 20, 10, 40]); // B,G,R,A
  });

  it("rejects an 'rgbaFp16' (HDR) target — the 8-bit helper can't fill a half-float buffer (#99)", () => {
    const ctx = makeCtx(4, 4, 'rgbaFp16');
    expect(() => drawWithRGBA(() => {})(ctx)).toThrow(/rgbaFp16.*HDR|8-bit-only/);
    // Must fail before writing anything — no silently mis-sized write.
    expect(ctx.target.writeBytes as unknown as jest.Mock).not.toHaveBeenCalled();
  });
});
