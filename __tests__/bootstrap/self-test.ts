/**
 * T023 — US13 bootstrap self-test.
 *
 * The canonical "canary" that must pass before any integration test
 * consumes a synthesized fixture. Two parts make the canary useful:
 *
 *   1) A **pattern formula tripwire** that locks the rotating-triangle
 *      `BOOTSTRAP_PATTERN` formula (defined once in
 *      `packages/react-native-video-pipeline/src/bootstrap-pattern.ts`)
 *      against a frozen center-pixel reference table. The library
 *      function `expectedCenterRGBA` is imported directly — there is no
 *      local re-implementation of the formula here. If
 *      `bootstrap-pattern.ts` drifts, this file's recomputation will
 *      not match the frozen table and `yarn test` fails with a clear
 *      diff before any native pipeline runs.
 *
 *   2) A **native round-trip** (encode → decode → center-pixel compare)
 *      that proves the synthesize pipeline still produces the expected
 *      output. That lives in the XCTest canary
 *      `apps/bare-example/ios/bareexampleTests/bareexampleTests.m::
 *      testSynthesizeSelfTestCanary` — a JS `Video.synthesize` driver
 *      is not runnable from Node/Jest because the worklet runtime and
 *      native module only exist in the RN app context. `yarn
 *      test:native` and `yarn smoke:ios` both execute that XCTest.
 *
 * Single source of truth: `BOOTSTRAP_PATTERN` is declared once in
 * `bootstrap-pattern.ts` and consumed by (a) this tripwire, (b) the
 * consumer-facing `fillBootstrapPattern` helper, and (c) T053's future
 * worklet-pump screen + T053a's `drawWithSkia` screen once the
 * `react-native-worklets-core` integration lands. A repo-wide grep for
 * `expectedCenterRGBA` / `bootstrapPatternRGBA` confirms the invariant.
 *
 * Deferred — pointer-path and Skia-helper pipeline canaries: T053's
 * `_passes_note` scopes the bare-example worklet smoke (drawFrame via
 * `ctx.target.writeBytes`) to a later sub-iteration once
 * `react-native-worklets-core` is wired. Until that lands, the XCTest
 * canary exercises the native `fillTestPatternRGBA` placeholder (whose
 * flat-triple output coincides with the BOOTSTRAP_PATTERN "outside"
 * branch) to verify the end-to-end encode/decode path. The pointer-path
 * and Skia-path round-trips that verify the inside-triangle branch
 * land with the worklet-runtime continuation.
 */

import {
  expectedCenterRGBA,
  type RGBA,
} from '../../packages/react-native-video-pipeline/src/bootstrap-pattern';

const SELF_TEST_WIDTH = 160;
const SELF_TEST_HEIGHT = 120;
const SELF_TEST_FRAME_COUNT = 20;

/**
 * Frozen center-pixel expectation for frames [0, SELF_TEST_FRAME_COUNT)
 * at the canonical 160×120 canvas. Recomputing this array from
 * `expectedCenterRGBA` and asserting equality is the drift tripwire —
 * a future change to the BOOTSTRAP_PATTERN formula will not silently
 * slip through, because this frozen literal is the contract.
 *
 * Values derived from the pattern definition (see `bootstrap-pattern.ts`):
 *   cx=80, cy=60, nx=128, ny=128 (integer floor of center normalisation).
 *   rot 0: (nx, ny, 0xff)         = (128, 128, 255)
 *   rot 1: (0xff - nx, ny, nx)    = (127, 128, 128)
 *   rot 2: (0, 0xff - ny, nx)     = (0, 127, 128)
 *   rot 3: (nx, 0, 0xff - ny)     = (128, 0, 127)
 * Frames cycle through rot 0..3 = frameIndex % 4.
 */
const EXPECTED_CENTER_RGBA_160x120: readonly (readonly [number, number, number, number])[] = [
  [128, 128, 255, 255], // frame 0  — rot 0
  [127, 128, 128, 255], // frame 1  — rot 1
  [0, 127, 128, 255], // frame 2  — rot 2
  [128, 0, 127, 255], // frame 3  — rot 3
  [128, 128, 255, 255], // frame 4  — rot 0
  [127, 128, 128, 255], // frame 5  — rot 1
  [0, 127, 128, 255], // frame 6  — rot 2
  [128, 0, 127, 255], // frame 7  — rot 3
  [128, 128, 255, 255], // frame 8  — rot 0
  [127, 128, 128, 255], // frame 9  — rot 1
  [0, 127, 128, 255], // frame 10 — rot 2
  [128, 0, 127, 255], // frame 11 — rot 3
  [128, 128, 255, 255], // frame 12 — rot 0
  [127, 128, 128, 255], // frame 13 — rot 1
  [0, 127, 128, 255], // frame 14 — rot 2
  [128, 0, 127, 255], // frame 15 — rot 3
  [128, 128, 255, 255], // frame 16 — rot 0
  [127, 128, 128, 255], // frame 17 — rot 1
  [0, 127, 128, 255], // frame 18 — rot 2
  [128, 0, 127, 255], // frame 19 — rot 3
];

function toTuple(px: RGBA): [number, number, number, number] {
  return [px.r, px.g, px.b, px.a];
}

describe('T023 — bootstrap/self-test', () => {
  it('BOOTSTRAP_PATTERN formula is stable at the frozen center-pixel table', () => {
    const actual: [number, number, number, number][] = [];
    for (let i = 0; i < SELF_TEST_FRAME_COUNT; i += 1) {
      actual.push(toTuple(expectedCenterRGBA(i, SELF_TEST_WIDTH, SELF_TEST_HEIGHT)));
    }
    expect(actual).toEqual(EXPECTED_CENTER_RGBA_160x120);
  });

  it('EXPECTED_CENTER_RGBA_160x120 covers exactly SELF_TEST_FRAME_COUNT frames', () => {
    expect(EXPECTED_CENTER_RGBA_160x120).toHaveLength(SELF_TEST_FRAME_COUNT);
  });

  it('center pixel cycles through four distinct colours per frameIndex % 4', () => {
    // Asymmetry guarantee: a future pattern simplification that collapses
    // the four per-rotation palettes to a single colour would hide flip /
    // rotation regressions. The four distinct center RGBs per rot cycle
    // is what makes BOOTSTRAP_PATTERN a useful canary, so we lock it in.
    const firstCycle = EXPECTED_CENTER_RGBA_160x120.slice(0, 4).map((t) => t.join(','));
    expect(new Set(firstCycle).size).toBe(4);
  });

  it('the alpha byte is always 0xff (the pattern never emits a transparent pixel)', () => {
    for (const [, , , a] of EXPECTED_CENTER_RGBA_160x120) {
      expect(a).toBe(0xff);
    }
  });
});
