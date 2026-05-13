# CLAUDE.md

Guidance for Claude (and any other coding agent) working in this repo. This file captures the load-bearing invariants that any agent must respect on every iteration. Architecture deep-dive in [`docs/architecture.md`](./docs/architecture.md); public API in [`docs/api.md`](./docs/api.md).

---

## Project in one paragraph

`react-native-video-pipeline` is a greenfield, MIT-licensed React Native **Nitro Module** for **offline** video editing — trim, flip, stamp, compose, synthesize, probe — targeting **iOS 13+** and **Android API 24+** on the **New Architecture only**. Three internal execution paths: **remux** (passthrough), **transcode** (native hot loop with platform-native overlays), **compose** (worklet-driven per-frame drawing via Skia on the consumer's side). The library ships a shared C++ core plus AVFoundation (iOS) and Media3 Transformer (Android) adapters.

---

## Hard invariants (do not violate)

If a task description appears to conflict with one of these, surface the conflict before loosening the invariant.

1. **Yarn only.** Yarn 4 (Berry) with `nodeLinker: node-modules`. The `packageManager` field in root `package.json` pins the exact version. `yarn.lock` is committed. CI uses `yarn install --immutable`. Never `npm`, never `pnpm`, never PnP.

2. **Both iOS and Android are first-class.** Android Media3 Transformer ships alongside iOS AVFoundation. No "Android is a stub" shortcuts.

3. **Zero Skia in the library.** Neither the C++ core nor the JS runtime may import or depend on `@shopify/react-native-skia`. Static image overlays use `CIFilter` + `CATextLayer` on iOS and Media3 `BitmapOverlay` + `TextOverlay` on Android. Skia appears only when a consumer opts into the `compose` worklet path and brings Skia themselves. Skia is listed in `peerDependenciesMeta` as optional — never in `dependencies` or `peerDependencies`.

4. **No FFmpeg, ever.** AVFoundation + Media3 Transformer only. The patent/license problem that killed `ffmpeg-kit-react-native` is the whole reason this library exists.

5. **Offline only.** No network calls. No realtime pacing, no clock-driven behavior. Output PTS is always `frameIndex / fps`, never wall-clock.

6. **Nitro spec is the single source of truth.** `packages/react-native-video-pipeline/src/nitro/VideoPipeline.nitro.ts` declares every cross-boundary type. JS, C++, Objective-C++, and Kotlin bindings are generated from it. Never hand-maintain parallel type definitions. When a type changes, edit the spec and run `yarn nitrogen`; never hand-edit files under `nitrogen/`.

7. **Type safety is non-negotiable.** `tsconfig` has `strict: true` plus `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, `noImplicitOverride`, `noFallthroughCasesInSwitch`. `yarn typecheck` must pass with zero suppressions. No `any` in the public API surface — `unknown` is fine where genuinely untyped. Discriminated unions (`Overlay.kind`, `DurationSpec.mode`, `VideoPipelineError.code`) have compile-time `assertNever` exhaustiveness checks in library code. No `@ts-ignore` / `@ts-expect-error` in `src/` — the only exception is a test that intentionally pins a type error.

8. **Worklet directive enforcement is build-time.** `babel-plugin-video-pipeline` fails the bundle if a function passed as a `FrameDrawer` is missing the `'worklet';` directive. Do not add runtime "first-frame-throws" fallback checks.

9. **Derived artifacts are gitignored and regenerated.** `nitrogen/` and `packages/react-native-video-pipeline/plugin/build/` are never committed. `plugin/build/` ships in the npm tarball via the `files` allowlist + a `prepack` script — not via git.

10. **Tests bootstrap their own fixtures.** `__tests__/bootstrap/` uses `Video.synthesize` to generate the inputs that remux/transcode/compose suites consume. Do not commit binary video files.

11. **Public API matches [`docs/api.md`](./docs/api.md) exactly.** Deviate only after that doc and the Nitro spec have been updated.

---

## Repo layout (yarn workspaces monorepo)

- `packages/react-native-video-pipeline/` — main library **and** the Expo config plugin (bundled in the same package so Expo's plugin resolver works).
- `packages/babel-plugin-video-pipeline/` — separate published package that enforces `'worklet';` directives at build time.
- `packages/react-native-video-pipeline-skia/` — consumer-side Skia helper (`drawWithSkia`); separate so the main library stays Skia-free.
- `apps/bare-example/`, `apps/expo-example/` — non-publishable consumer apps for local verification.
- `__tests__/bootstrap/` — synthesize-driven fixture generation.
- `__tests__/golden/{ios,android}/*.hash` — cross-platform pixel-hash parity.

Full tree and module inventory in [`docs/architecture.md`](./docs/architecture.md).

---

## Per-iteration verification (run from repo root)

- `yarn lint` — Biome (primary) + ESLint (RN-only rules).
- `yarn format` — Biome formatter; must leave a clean tree.
- `yarn typecheck` — strict, zero suppressions, zero errors.
- `yarn test` — Jest, where JS tests exist for the touched area.
- `yarn test:native` — **default for any change to `cpp/**` or `ios/**/*.{h,mm}`.** Compiles against `-sdk macosx` and runs the XCTests directly on the host (~6s end-to-end, no simulator). Covers the full AVFoundation/CoreVideo surface — AVMuxer, AVDemuxer, WorkletFrameBridge, SynthesizeRunner, Remuxer, ComposeRunner, StopToken. Any remux / transcode / probe / thumbnail work lives entirely under this path.
- `yarn smoke:ios` — **only run when the task genuinely exercises the RN → Nitro → native bridge** (JS calling through Nitro into C++/Obj-C++ at runtime). Concretely: when the change modifies `src/video.ts`, `src/native.ts`, the Nitro spec, `VideoPipeline.mm`, or anything that needs Metro + Hermes + the HybridObject registry. It runs lint + typecheck + `yarn test` + `yarn test:native`, then `pod install`s and `xcodebuild test`s bare-example in a simulator — 3–5 min per run. Do NOT run it for work that only touches AVFoundation code `yarn test:native` already covers. This is the local gate the future CI workflow will run.
- iOS: `yarn workspace bare-example run ios` (via Pods + `xcodebuild`) when native iOS code changed.
- Android: `yarn workspace bare-example run android` (via Gradle) when native Android code changed.

### xcodebuild in headless/agent runs

`xcodebuild` from a fresh checkout will silently hang forever if it hits a Swift-package / macro trust prompt or any signing prompt — there is no GUI to answer. Always pass these flags for simulator builds and tests:

```
xcodebuild ... \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -allowProvisioningUpdates \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_IDENTITY=""
```

For **`test` actions**, also enable per-test timeouts so a wedged test fails fast instead of burning the 10-minute xcodebuild watchdog:

```
... test \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 5 \
  -maximum-test-execution-time-allowance 30
```

Every native test in this repo authors at most ~1 second of tiny-dimension video. Anything exceeding 5s is wedged, not slow.

If a run exceeds ~2 minutes with no output, it is almost certainly stuck on one of the validation prompts — kill the hung `xcodebuild` PID, re-run with the flags above, and move on. Do not wait it out.

A task is not "done" until every check that applies to its diff passes locally. CI is deliberately the last task — local verification is the gate throughout.

---

## Task workflow

The two task-style flows below are kept separate on purpose. Pick the one that matches what you're doing:

### Planned-TODO flow (the original Ralph loop)

Used for the staged feature work that filled the v0.1 roadmap. The defining trait: a real entry in `TODO.md` with `priority` and `depends_on` you can read off the file.

1. Read `activity.md` to see what's already done.
2. In `TODO.md` (gitignored, local), find the lowest-`priority` open task whose `depends_on` are all done.
3. Implement exactly **one** task per iteration.
4. Run the applicable checks above.
5. Append a dated entry to `activity.md` — what changed, what commands ran, issues + resolutions.
6. Move that task from "Open" to "Done" in `TODO.md`.
7. Commit on a dedicated feature branch (`fix/...`, `feat/...`, `chore/...`) — one commit per task, branched from `main`. Never push. Never commit to `main`.

### Ad-hoc work flow

Used for everything else — bug reports, consumer-driven investigations, follow-up fixes after v0.1.0 shipped, refactors that didn't go through `TODO.md`. The defining trait: the work was driven by an active conversation, not a queued task.

1. Skip `TODO.md` / `activity.md`. Those files are for planned work; cluttering them with ad-hoc churn defeats the point.
2. Run the applicable checks above (lint / format / typecheck / tests as the diff warrants) the same as planned work.
3. Commit on a topic branch named for the change (`fix/<symptom>`, `feat/<thing>`, `chore/<task>`) branched from `main`. One logical change per commit. Never push. Never commit to `main`.

> **Historical note:** before v0.1.0 shipped (commit `494e1f9`), iteration commits accumulated on a single `v0.1` integration branch — that's why prior versions of this section said "commit to branch `v0.1`." After release, that branch's purpose ended; new work goes on properly-named topic branches branched from `main`.

---

## See also

- [`docs/architecture.md`](./docs/architecture.md) — repo layout, tech stack, module inventory, locked-in design decisions.
- [`docs/api.md`](./docs/api.md) — public API reference.
- [`docs/examples/`](./docs/examples/) — runnable scenarios per operation.
- [`docs/rendering-ios.md`](./docs/rendering-ios.md) — the three iOS render paths (vanilla bytes, Skia CPU readback, Skia GPU-optimized) and how they all share `CVPixelBuffer`. Read before cross-cutting changes to the iOS render pipeline.
- [`docs/rendering-android.md`](./docs/rendering-android.md) — Android pipeline (synthesize + compose-on-clip), Y-flip discipline at memory↔GL boundaries, AHardwareBuffer source path. Read before cross-cutting changes to the Android render pipeline.
- `AGENTS.md` — same invariants, mirrored for non-Claude agents (Codex, Cursor, etc.).
- `CONTRIBUTING.md` — human-contributor dev setup + commit style.
- `TODO.md`, `ROADMAP.md`, `activity.md` — local-only planning files (gitignored).
