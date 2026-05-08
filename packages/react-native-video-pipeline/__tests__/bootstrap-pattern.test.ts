import {
  bootstrapPatternRGBA,
  expectedCenterRGBA,
  fillBootstrapPattern,
} from '../src/bootstrap-pattern';

describe('bootstrapPatternRGBA', () => {
  it('center pixel is inside for every rotation (1..8)', () => {
    // Invariant: expectedCenterRGBA never falls into the "outside" branch,
    // so T023's canary gets a deterministic triangle-RGB value at (w/2, h/2)
    // for every frame index regardless of orientation.
    const w = 160;
    const h = 120;
    for (let f = 0; f < 8; f += 1) {
      const c = bootstrapPatternRGBA(f, Math.floor(w / 2), Math.floor(h / 2), w, h);
      const outside = {
        r: (f * 11) & 0xff,
        g: (f * 53) & 0xff,
        b: (f * 97) & 0xff,
      };
      expect(c).not.toEqual({ ...outside, a: 0xff });
    }
  });

  it('frame 0 center: triangle-gradient rot 0 formula', () => {
    const w = 160;
    const h = 120;
    const c = expectedCenterRGBA(0, w, h);
    const nxCenter = Math.floor((Math.floor(w / 2) * 255) / (w - 1));
    const nyCenter = Math.floor((Math.floor(h / 2) * 255) / (h - 1));
    expect(c).toEqual({ r: nxCenter, g: nyCenter, b: 0xff, a: 0xff });
  });

  it('rot cycles through 4 orientations', () => {
    // frames 0,1,2,3 must produce distinct center RGBAs — asymmetry guarantee
    const w = 160;
    const h = 120;
    const set = new Set<string>();
    for (let f = 0; f < 4; f += 1) {
      const c = expectedCenterRGBA(f, w, h);
      set.add(`${c.r},${c.g},${c.b}`);
    }
    expect(set.size).toBe(4);
  });

  it('handles 1x1 width/height without NaN', () => {
    // Edge case: a 1x1 render would divide by zero without the Math.max(1, ...)
    // clamp. Not a real use case, but a safety net for degenerate fixtures.
    const c = bootstrapPatternRGBA(0, 0, 0, 1, 1);
    expect(Number.isFinite(c.r)).toBe(true);
    expect(Number.isFinite(c.g)).toBe(true);
    expect(Number.isFinite(c.b)).toBe(true);
    expect(c.a).toBe(0xff);
  });
});

describe('fillBootstrapPattern', () => {
  it('BGRA8888 vs RGBA8888 swap channels at the same pixel', () => {
    const w = 4;
    const h = 4;
    const rowBytes = w * 4;
    const rgba = new Uint8Array(rowBytes * h);
    const bgra = new Uint8Array(rowBytes * h);
    fillBootstrapPattern(rgba, 2, w, h, rowBytes, 'rgba8888');
    fillBootstrapPattern(bgra, 2, w, h, rowBytes, 'bgra8888');
    // Pixel (1, 1): the first three bytes are (r,g,b) or (b,g,r), alpha is
    // 0xff in both; the R and B bytes swap, green + alpha match.
    const idx = 1 * rowBytes + 1 * 4;
    expect(rgba[idx + 0]).toBe(bgra[idx + 2]);
    expect(rgba[idx + 1]).toBe(bgra[idx + 1]);
    expect(rgba[idx + 2]).toBe(bgra[idx + 0]);
    expect(rgba[idx + 3]).toBe(bgra[idx + 3]);
    expect(rgba[idx + 3]).toBe(0xff);
  });

  it('fills every pixel (no stride gap leaks)', () => {
    const w = 8;
    const h = 6;
    const rowBytes = w * 4;
    const out = new Uint8Array(rowBytes * h);
    fillBootstrapPattern(out, 1, w, h, rowBytes, 'rgba8888');
    // Every alpha byte must be 0xff — confirms we touched every pixel.
    for (let y = 0; y < h; y += 1) {
      for (let x = 0; x < w; x += 1) {
        expect(out[y * rowBytes + x * 4 + 3]).toBe(0xff);
      }
    }
  });
});
