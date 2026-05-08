/**
 * T024 — US13 bootstrap generators.
 *
 * Declares the four canonical v0.1 bootstrap fixtures that the
 * downstream remux / transcode / compose suites will consume once the
 * integration harness comes online (T048 Maestro + golden-file suite):
 *
 *   1. `animated1080p30x3s` — 1920×1080 @ 30fps for 3s (90 frames).
 *   2. `gradient4K60x1s`    — 3840×2160 @ 60fps for 1s (60 frames).
 *   3. `rotated720p`        — 1280× 720 @ 30fps for 1s, rotation=90.
 *   4. `hdrFlag720p`        — 1280× 720 @ 30fps for 1s, isHDR flag.
 *
 * Three-layer verification — this file is the **config tripwire** that
 * freezes what the four fixtures *must* be; the production path runs
 * in a real RN process:
 *
 * 1. **Jest tripwire (this file)** — a frozen FIXTURES table asserted
 *    against `expectedFrameCount` so any drift in the declared shape
 *    fails `yarn test` before it can silently feed the wrong input
 *    into a downstream suite. Runs in Node, cannot call
 *    `Video.synthesize` directly (no RN runtime, no native module).
 *
 * 2. **Bare-example runtime generation (T024 post-T054c/d)** — the
 *    bare-example app exposes a `run-bootstrap-fixtures` button
 *    (`apps/bare-example/App.tsx`) that invokes `Video.synthesize` for
 *    each fixture through the real JS → Nitro → renderCompose →
 *    HybridFrameTarget pipeline using `drawWithRGBA` +
 *    `bootstrapPatternRGBA`. The per-pixel content is asymmetric by
 *    design (flipping or rotating the output shifts probe values
 *    outside ±32/255). The Maestro flow
 *    `.maestro/bootstrap-fixtures-probe.yaml` taps the button and
 *    asserts each fixture kind appears in the result text.
 *
 *    Proxy resolutions (160×120) on the bare-example button keep the
 *    Maestro flow under a few seconds. Full declared resolutions
 *    (1080p/4K/720p) land in T048's golden-file suite where CI has the
 *    budget for 4K/60 encodes.
 *
 * 3. **Legacy macOS-host canary** —
 *    `packages/react-native-video-pipeline/ios/__tests__/LibraryTests.m::
 *    testBootstrapGenerators60fpsCanary` exercises a 160×120 / 20-frame
 *    / 60fps synthesize round-trip through the C++ placeholder path,
 *    kept green so refactors of AVMuxer/SynthesizeRunner surface
 *    immediately.
 *
 * The `rotation` and `isHDR` flags are metadata-only descriptors today:
 * the Nitro `OutputSpec` / `MetadataSpec` (`src/nitro/
 * VideoPipeline.nitro.ts`) does not yet carry either field on the
 * synthesize path, so the bare-example button only proves the
 * generator path produces each fixture's MP4. Baking rotation and HDR
 * colr atoms into the AVMuxer output is deferred to the transcode path
 * tasks (T026+) when source-clip metadata plumbing lands end-to-end.
 */

type FixtureKind = 'animated' | 'gradient' | 'rotated' | 'hdrFlag';

interface FixtureConfig {
  readonly kind: FixtureKind;
  readonly width: number;
  readonly height: number;
  readonly fps: number;
  readonly seconds: number;
  /** Declarative only in v0.1; applied by the transcode path in T026+. */
  readonly rotation?: 0 | 90 | 180 | 270;
  /** Declarative only in v0.1; colr-atom plumbing lands post-1.0. */
  readonly isHDR?: boolean;
}

const FIXTURES: Readonly<Record<FixtureKind, FixtureConfig>> = {
  animated: { kind: 'animated', width: 1920, height: 1080, fps: 30, seconds: 3 },
  gradient: { kind: 'gradient', width: 3840, height: 2160, fps: 60, seconds: 1 },
  rotated: { kind: 'rotated', width: 1280, height: 720, fps: 30, seconds: 1, rotation: 90 },
  hdrFlag: { kind: 'hdrFlag', width: 1280, height: 720, fps: 30, seconds: 1, isHDR: true },
};

function expectedFrameCount(f: FixtureConfig): number {
  return Math.round(f.fps * f.seconds);
}

describe('T024 — bootstrap/generators', () => {
  it('declares exactly the four canonical v0.1 fixtures', () => {
    expect(Object.keys(FIXTURES).sort()).toEqual(
      (['animated', 'gradient', 'hdrFlag', 'rotated'] as const).slice().sort(),
    );
  });

  it('FIXTURES.animated is the 1080p/30 3s animated pattern', () => {
    expect(FIXTURES.animated).toEqual({
      kind: 'animated',
      width: 1920,
      height: 1080,
      fps: 30,
      seconds: 3,
    });
    expect(expectedFrameCount(FIXTURES.animated)).toBe(90);
  });

  it('FIXTURES.gradient is the 4K/60 1s gradient', () => {
    expect(FIXTURES.gradient).toEqual({
      kind: 'gradient',
      width: 3840,
      height: 2160,
      fps: 60,
      seconds: 1,
    });
    expect(expectedFrameCount(FIXTURES.gradient)).toBe(60);
  });

  it('FIXTURES.rotated carries rotation metadata; other dimensions are 720p/30 1s', () => {
    expect(FIXTURES.rotated).toEqual({
      kind: 'rotated',
      width: 1280,
      height: 720,
      fps: 30,
      seconds: 1,
      rotation: 90,
    });
    expect(expectedFrameCount(FIXTURES.rotated)).toBe(30);
  });

  it('FIXTURES.hdrFlag carries the HDR flag; other dimensions are 720p/30 1s', () => {
    expect(FIXTURES.hdrFlag).toEqual({
      kind: 'hdrFlag',
      width: 1280,
      height: 720,
      fps: 30,
      seconds: 1,
      isHDR: true,
    });
    expect(expectedFrameCount(FIXTURES.hdrFlag)).toBe(30);
  });

  it('frame counts across all fixtures match the XCTest mirror (bareexampleTests.m T024)', () => {
    // Frozen vector — if you change any FIXTURES entry, update the
    // matching kRNVPT024Fixtures table in bareexampleTests.m to keep the
    // JS tripwire and the native pipeline canary in lockstep.
    const counts = (['animated', 'gradient', 'rotated', 'hdrFlag'] as const).map((k) =>
      expectedFrameCount(FIXTURES[k]),
    );
    expect(counts).toEqual([90, 60, 30, 30]);
  });
});
