# Golden pixel-hash suite (T048)

Cross-platform pixel-parity regression for the render pipeline. The same
deterministic `VideoSpec` is rendered on iOS and Android, sampled frames are
reduced to a low-resolution RGB signature, and the signatures are checked two
ways:

- **Regression** — each platform's fresh signature vs its committed reference
  in `ios/*.hash` / `android/*.hash`. The decode is deterministic, so this is
  effectively exact (Δ≈0).
- **Cross-platform parity** — iOS vs Android, within a perceptual tolerance.

Run it:

```sh
yarn test:golden            # render both platforms + verify
yarn test:golden --update   # regenerate + rewrite the committed references
yarn test:golden --no-render # verify using existing build/golden dumps
yarn test:golden --platform android   # one platform only
```

Orchestrator: [`scripts/golden.mjs`](../../scripts/golden.mjs) (dependency-free Node).

## App-free architecture

Rendering is driven through the native test harnesses — **no app, and for iOS
no simulator**:

- **Android** — the `GoldenRenderTest` instrumented test renders via
  `SynthesizeRunner.runFixed`, extracts frames with `getFrameAtIndex`, and
  writes raw RGBA dumps to `Download/rnvp-golden/` (pulled with `adb`).
- **iOS** — the `testGoldenDumpFrames` XCTest (run by `yarn test:native` on the
  macOS host) renders via `RNVPSynthesizeRunner`, extracts frames with
  `AVAssetReader` (raw decoder output — **not** `AVAssetImageGenerator`, which
  colour-manages and shifts values), and writes RGBA dumps to `$RNVP_GOLDEN_DIR`.

The host script reduces each dump to an 8×8 RGB average grid and compares.

## Why `synthesize`, and why these tolerances

The built-in synthesize pattern is a flat per-frame colour
`(i*11, i*53, i*97) & 0xff` implemented **identically** in
`ios/SynthesizeRunner.mm` and `android/SynthesizeRunner.kt`, so the content is
byte-identical *before* encoding — the cleanest deterministic cross-platform
input. Frames are sampled by exact index (`(N+0.1)/fps` on Android,
sequential read on iOS) so both platforms hash the same frames.

Tolerances live in `scripts/golden.mjs`:

- `REGRESSION_TOL = 3` — same platform; observed Δ = 0.
- `CROSS_TOL = 14` (≈5.5%) — **strict 0.5% cross-platform parity is not
  achievable.** AVFoundation (`AVAssetReader`) and Android `MediaCodec` decode
  H.264 to RGB with different YUV range/matrix handling; the green channel in
  particular drifts ~10–20 on saturated frames (observed signature Δ up to
  ~10.6). The bound still catches gross divergence (wrong frame, flip, channel
  swap → Δ ≫ 14). Text overlays are even less comparable (platform font
  shaping) and are intentionally out of the cross-platform set — they are
  covered per-platform by the T045 unit tests.

## Files

- `ios/synthesize.hash`, `android/synthesize.hash` — committed references
  (one hex line per sampled frame). Regenerate with `--update` and review the
  diff before committing.
- Transient render dumps go to `build/golden/` (gitignored).
