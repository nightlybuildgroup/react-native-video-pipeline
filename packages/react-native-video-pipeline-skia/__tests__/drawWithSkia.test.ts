// Unit tests for the `drawWithSkia` helper. Skia is an optional peer dep and
// is not installed in this monorepo, so the test mocks the module surface
// that `drawWithSkia` touches. The assertions focus on the helper's
// boilerplate-removal contract:
//   - allocates an offscreen surface sized to the frame
//   - pre-draws a source native buffer when `ctx.source` is set
//   - calls the user callback with the canvas + context
//   - reads pixels with the platform-correct color type (CPU fallback)
//   - forwards pixels to `ctx.target.writeBytes` as an ArrayBuffer (CPU)
//   - takes the GPU fast path when `getNativeTextureUnstable` is available
//     and returns a usable bigint, routing through blitFromNativeTexture
//   - falls back to CPU on shape drift (non-bigint, zero, or throw) with a
//     single console.warn per process
//   - disposes every Skia handle in `finally` even if the callback throws
//
// The native pixel-equivalence proof vs T053's pointer-path screen lives in
// the bare-example smoke harness (blocked on the T053 worklet-runtime
// follow-up); these tests lock the JS-side contract independently.

import type {
  FrameDrawerContext,
  FrameSource,
  FrameTarget,
} from '../../react-native-video-pipeline/src/nitro/VideoPipeline.nitro';

type SkImageMock = {
  readPixels: jest.Mock;
  dispose: jest.Mock;
};
type SkSurfaceMock = {
  getCanvas: jest.Mock;
  flush: jest.Mock;
  makeImageSnapshot: jest.Mock;
  getNativeTextureUnstable?: jest.Mock;
  dispose: jest.Mock;
};
type SkCanvasMock = {
  drawImage: jest.Mock;
};

const drawImage = jest.fn();
const canvas: SkCanvasMock = { drawImage };

let latestSurface: SkSurfaceMock | null = null;
let latestSnapshot: SkImageMock | null = null;
let latestSourceImage: SkImageMock | null = null;

const makeImageFromNativeBuffer = jest.fn((_addr: bigint) => {
  const img: SkImageMock = {
    readPixels: jest.fn(),
    dispose: jest.fn(),
  };
  latestSourceImage = img;
  return img;
});

const makeOffscreen: jest.Mock<SkSurfaceMock | null, [number, number]> = jest.fn(
  (w: number, h: number): SkSurfaceMock | null => {
    const readPixels = jest.fn(() => {
      const pixels = new Uint8Array(w * h * 4);
      pixels.fill(0x42);
      return pixels;
    });
    const snapshot: SkImageMock = { readPixels, dispose: jest.fn() };
    latestSnapshot = snapshot;
    const surface: SkSurfaceMock = {
      getCanvas: jest.fn(() => canvas),
      flush: jest.fn(),
      makeImageSnapshot: jest.fn(() => snapshot),
      dispose: jest.fn(),
    };
    latestSurface = surface;
    return surface;
  },
);

jest.mock(
  '@shopify/react-native-skia',
  () => ({
    Skia: {
      Surface: { MakeOffscreen: makeOffscreen },
      Image: { MakeImageFromNativeBuffer: makeImageFromNativeBuffer },
    },
    ColorType: { RGBA_8888: 1, BGRA_8888: 2 },
    AlphaType: { Premul: 3 },
  }),
  { virtual: true },
);

import { drawWithSkia } from '../src/drawWithSkia';

function makeTarget(
  format: 'bgra8888' | 'rgba8888',
  w: number,
  h: number,
  blitImpl?: (mtlTexturePtr: bigint) => void,
): FrameTarget {
  return {
    bufferAddr: 0xdeadbeefn,
    width: w,
    height: h,
    format,
    writeBytes: jest.fn(),
    blitFromNativeTexture: jest.fn(blitImpl ?? (() => {})),
  };
}

function makeCtx(
  width: number,
  height: number,
  format: 'bgra8888' | 'rgba8888',
  source?: FrameSource,
  target?: FrameTarget,
): FrameDrawerContext {
  return {
    frameIndex: 0,
    timeSec: 0,
    elapsedMs: 0,
    width,
    height,
    target: target ?? makeTarget(format, width, height),
    ...(source !== undefined ? { source } : {}),
    finish: jest.fn(),
  };
}

beforeEach(() => {
  drawImage.mockClear();
  makeImageFromNativeBuffer.mockClear();
  makeOffscreen.mockClear();
  latestSurface = null;
  latestSnapshot = null;
  latestSourceImage = null;
});

describe('drawWithSkia', () => {
  it('runs the user callback with a canvas + context and writes pixels to the target', () => {
    const cb = jest.fn();
    const ctx = makeCtx(16, 8, 'bgra8888');
    drawWithSkia(cb)(ctx);

    expect(makeOffscreen).toHaveBeenCalledWith(16, 8);
    expect(cb).toHaveBeenCalledTimes(1);
    expect(cb.mock.calls[0]?.[0]).toBe(canvas);
    expect(cb.mock.calls[0]?.[1]).toBe(ctx);

    const write = ctx.target.writeBytes as unknown as jest.Mock;
    expect(write).toHaveBeenCalledTimes(1);
    const arg = write.mock.calls[0]?.[0];
    expect(arg).toBeInstanceOf(ArrayBuffer);
    expect((arg as ArrayBuffer).byteLength).toBe(16 * 8 * 4);
  });

  it('selects BGRA color type on iOS-format targets and RGBA on Android-format targets', () => {
    const ctx1 = makeCtx(4, 4, 'bgra8888');
    drawWithSkia(() => {})(ctx1);
    const call1 = latestSnapshot?.readPixels.mock.calls[0];
    expect(call1?.[2]).toMatchObject({ colorType: 2, alphaType: 3 });

    const ctx2 = makeCtx(4, 4, 'rgba8888');
    drawWithSkia(() => {})(ctx2);
    const call2 = latestSnapshot?.readPixels.mock.calls[0];
    expect(call2?.[2]).toMatchObject({ colorType: 1, alphaType: 3 });
  });

  it('pre-draws ctx.source onto the canvas when provided (compose-on-clip path)', () => {
    const source: FrameSource = {
      bufferAddr: 0x1234n,
      width: 4,
      height: 4,
      format: 'bgra8888',
    };
    const ctx = makeCtx(4, 4, 'bgra8888', source);
    const cb = jest.fn();
    drawWithSkia(cb)(ctx);

    expect(makeImageFromNativeBuffer).toHaveBeenCalledWith(0x1234n);
    expect(drawImage).toHaveBeenCalledTimes(1);
    expect(drawImage.mock.calls[0]?.[0]).toBe(latestSourceImage);
    // The source draw happens BEFORE the user callback — so the user can
    // layer on top rather than fighting with it.
    const drawImageOrder = drawImage.mock.invocationCallOrder[0] ?? 0;
    const callbackOrder = cb.mock.invocationCallOrder[0] ?? 0;
    expect(drawImageOrder).toBeLessThan(callbackOrder);
  });

  it('does not invoke MakeImageFromNativeBuffer when ctx.source is undefined', () => {
    const ctx = makeCtx(4, 4, 'bgra8888');
    drawWithSkia(() => {})(ctx);
    expect(makeImageFromNativeBuffer).not.toHaveBeenCalled();
    expect(drawImage).not.toHaveBeenCalled();
  });

  it('disposes the surface, snapshot, and source image even when the callback throws', () => {
    const source: FrameSource = {
      bufferAddr: 0x1n,
      width: 4,
      height: 4,
      format: 'bgra8888',
    };
    const ctx = makeCtx(4, 4, 'bgra8888', source);
    const fn = drawWithSkia(() => {
      throw new Error('consumer bug');
    });
    expect(() => fn(ctx)).toThrow('consumer bug');

    // Surface is always disposed; source image is disposed if it was created.
    // Snapshot is only created after the callback returns successfully — on
    // throw the snapshot is still null, nothing to dispose on that front.
    expect(latestSurface?.dispose).toHaveBeenCalledTimes(1);
    expect(latestSourceImage?.dispose).toHaveBeenCalledTimes(1);
  });

  it('throws a descriptive error when MakeOffscreen returns null', () => {
    makeOffscreen.mockImplementationOnce(() => null);
    const ctx = makeCtx(4, 4, 'bgra8888');
    expect(() => drawWithSkia(() => {})(ctx)).toThrow(/MakeOffscreen returned null/);
  });

  it('throws a descriptive error when readPixels returns null', () => {
    makeOffscreen.mockImplementationOnce(() => {
      const readPixels = jest.fn(() => null);
      const snapshot: SkImageMock = { readPixels, dispose: jest.fn() };
      latestSnapshot = snapshot;
      const surface: SkSurfaceMock = {
        getCanvas: jest.fn(() => canvas),
        flush: jest.fn(),
        makeImageSnapshot: jest.fn(() => snapshot),
        dispose: jest.fn(),
      };
      latestSurface = surface;
      return surface;
    });
    const ctx = makeCtx(4, 4, 'bgra8888');
    expect(() => drawWithSkia(() => {})(ctx)).toThrow(/readPixels returned null/);
    // Surface still disposed on the failure path.
    expect(latestSurface?.dispose).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------
  // T053b GPU fast path
  // ---------------------------------------------------------------------

  it('takes the GPU fast path when getNativeTextureUnstable returns a bigint', () => {
    const texPtr = 0xcafef00dn;
    const getNativeTextureUnstable = jest.fn(() => texPtr);
    makeOffscreen.mockImplementationOnce((w: number, h: number) => {
      const readPixels = jest.fn(() => {
        const pixels = new Uint8Array(w * h * 4);
        return pixels;
      });
      const snapshot: SkImageMock = { readPixels, dispose: jest.fn() };
      latestSnapshot = snapshot;
      const surface: SkSurfaceMock = {
        getCanvas: jest.fn(() => canvas),
        flush: jest.fn(),
        makeImageSnapshot: jest.fn(() => snapshot),
        getNativeTextureUnstable,
        dispose: jest.fn(),
      };
      latestSurface = surface;
      return surface;
    });

    const target = makeTarget('bgra8888', 4, 4);
    const ctx = makeCtx(4, 4, 'bgra8888', undefined, target);
    drawWithSkia(() => {})(ctx);

    expect(getNativeTextureUnstable).toHaveBeenCalledTimes(1);
    expect(target.blitFromNativeTexture).toHaveBeenCalledWith(texPtr);
    // GPU path skips snapshot + readPixels + writeBytes entirely.
    expect(latestSnapshot?.readPixels).not.toHaveBeenCalled();
    expect(target.writeBytes).not.toHaveBeenCalled();
  });

  it('falls back to CPU path when getNativeTextureUnstable returns a non-bigint shape', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    try {
      const getNativeTextureUnstable = jest.fn(() => ({ wrapped: 1 }) as unknown as bigint);
      makeOffscreen.mockImplementationOnce((w: number, h: number) => {
        const readPixels = jest.fn(() => new Uint8Array(w * h * 4));
        const snapshot: SkImageMock = { readPixels, dispose: jest.fn() };
        latestSnapshot = snapshot;
        const surface: SkSurfaceMock = {
          getCanvas: jest.fn(() => canvas),
          flush: jest.fn(),
          makeImageSnapshot: jest.fn(() => snapshot),
          getNativeTextureUnstable,
          dispose: jest.fn(),
        };
        latestSurface = surface;
        return surface;
      });

      const target = makeTarget('bgra8888', 4, 4);
      const ctx = makeCtx(4, 4, 'bgra8888', undefined, target);
      drawWithSkia(() => {})(ctx);

      expect(target.blitFromNativeTexture).not.toHaveBeenCalled();
      expect(target.writeBytes).toHaveBeenCalledTimes(1);
      expect(warn).toHaveBeenCalled();
      const firstCall = warn.mock.calls[0]?.[0];
      expect(firstCall).toMatch(/unexpected shape/);
    } finally {
      warn.mockRestore();
    }
  });

  it('falls back to CPU path when getNativeTextureUnstable returns 0n', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    try {
      const getNativeTextureUnstable = jest.fn(() => 0n);
      makeOffscreen.mockImplementationOnce((w: number, h: number) => {
        const readPixels = jest.fn(() => new Uint8Array(w * h * 4));
        const snapshot: SkImageMock = { readPixels, dispose: jest.fn() };
        latestSnapshot = snapshot;
        const surface: SkSurfaceMock = {
          getCanvas: jest.fn(() => canvas),
          flush: jest.fn(),
          makeImageSnapshot: jest.fn(() => snapshot),
          getNativeTextureUnstable,
          dispose: jest.fn(),
        };
        latestSurface = surface;
        return surface;
      });

      const target = makeTarget('bgra8888', 4, 4);
      const ctx = makeCtx(4, 4, 'bgra8888', undefined, target);
      drawWithSkia(() => {})(ctx);

      expect(target.blitFromNativeTexture).not.toHaveBeenCalled();
      expect(target.writeBytes).toHaveBeenCalledTimes(1);
    } finally {
      warn.mockRestore();
    }
  });

  it('falls back to CPU path when blitFromNativeTexture throws', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    try {
      const texPtr = 0x1n;
      const getNativeTextureUnstable = jest.fn(() => texPtr);
      makeOffscreen.mockImplementationOnce((w: number, h: number) => {
        const readPixels = jest.fn(() => new Uint8Array(w * h * 4));
        const snapshot: SkImageMock = { readPixels, dispose: jest.fn() };
        latestSnapshot = snapshot;
        const surface: SkSurfaceMock = {
          getCanvas: jest.fn(() => canvas),
          flush: jest.fn(),
          makeImageSnapshot: jest.fn(() => snapshot),
          getNativeTextureUnstable,
          dispose: jest.fn(),
        };
        latestSurface = surface;
        return surface;
      });

      const target = makeTarget('bgra8888', 4, 4, () => {
        throw new Error('native blit unavailable');
      });
      const ctx = makeCtx(4, 4, 'bgra8888', undefined, target);
      drawWithSkia(() => {})(ctx);

      expect(target.blitFromNativeTexture).toHaveBeenCalledWith(texPtr);
      // Fallback CPU write happens after the blit throw.
      expect(target.writeBytes).toHaveBeenCalledTimes(1);
      expect(warn).toHaveBeenCalled();
    } finally {
      warn.mockRestore();
    }
  });

  it('uses the CPU path when the surface lacks getNativeTextureUnstable entirely', () => {
    // Default mock already omits getNativeTextureUnstable — this documents
    // that the feature-detect is non-fatal for older Skia builds.
    const target = makeTarget('bgra8888', 4, 4);
    const ctx = makeCtx(4, 4, 'bgra8888', undefined, target);
    drawWithSkia(() => {})(ctx);

    expect(target.blitFromNativeTexture).not.toHaveBeenCalled();
    expect(target.writeBytes).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------
  // T054 / SMOKE_FORCE_CPU_READBACK — bit-identical GPU-vs-CPU parity hook
  // ---------------------------------------------------------------------

  describe('SMOKE_FORCE_CPU_READBACK env var', () => {
    const prev = process.env.SMOKE_FORCE_CPU_READBACK;
    afterEach(() => {
      if (prev === undefined) delete process.env.SMOKE_FORCE_CPU_READBACK;
      else process.env.SMOKE_FORCE_CPU_READBACK = prev;
    });

    function surfaceWithGpu(texPtr: bigint) {
      const getNativeTextureUnstable = jest.fn(() => texPtr);
      makeOffscreen.mockImplementationOnce((w: number, h: number) => {
        const readPixels = jest.fn(() => new Uint8Array(w * h * 4));
        const snapshot: SkImageMock = { readPixels, dispose: jest.fn() };
        latestSnapshot = snapshot;
        const surface: SkSurfaceMock = {
          getCanvas: jest.fn(() => canvas),
          flush: jest.fn(),
          makeImageSnapshot: jest.fn(() => snapshot),
          getNativeTextureUnstable,
          dispose: jest.fn(),
        };
        latestSurface = surface;
        return surface;
      });
      return getNativeTextureUnstable;
    }

    it.each([
      '1',
      'true',
      'yes',
      'TRUE',
      'Yes',
    ])('forces the CPU path when SMOKE_FORCE_CPU_READBACK=%s even if the GPU path is wired', (value) => {
      process.env.SMOKE_FORCE_CPU_READBACK = value;
      const getTex = surfaceWithGpu(0xcafef00dn);
      const target = makeTarget('bgra8888', 4, 4);
      const ctx = makeCtx(4, 4, 'bgra8888', undefined, target);
      drawWithSkia(() => {})(ctx);

      expect(getTex).not.toHaveBeenCalled();
      expect(target.blitFromNativeTexture).not.toHaveBeenCalled();
      expect(target.writeBytes).toHaveBeenCalledTimes(1);
    });

    it.each([
      '0',
      'false',
      'no',
      '',
      'anything-else',
    ])('keeps the GPU path when SMOKE_FORCE_CPU_READBACK=%j (non-truthy)', (value) => {
      process.env.SMOKE_FORCE_CPU_READBACK = value;
      surfaceWithGpu(0xabcdn);
      const target = makeTarget('bgra8888', 4, 4);
      const ctx = makeCtx(4, 4, 'bgra8888', undefined, target);
      drawWithSkia(() => {})(ctx);

      expect(target.blitFromNativeTexture).toHaveBeenCalledTimes(1);
      expect(target.writeBytes).not.toHaveBeenCalled();
    });
  });
});
