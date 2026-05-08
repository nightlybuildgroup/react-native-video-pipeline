# AGENTS.md

Guidance for any coding agent (Codex, Cursor, Aider, etc.) working in this repo. The conventions are identical to `CLAUDE.md` — this file exists so agents that look for `AGENTS.md` by default find the same invariants without a level of indirection.

---

## Project in one paragraph

`react-native-video-pipeline` is a greenfield, MIT-licensed React Native **Nitro Module** for **offline** video editing — trim, flip, stamp, compose, synthesize, probe — targeting **iOS 13+** and **Android API 24+** on the **New Architecture only**. Three internal execution paths: **remux** (passthrough), **transcode** (native hot loop with platform-native overlays), **compose** (worklet-driven per-frame drawing via Skia on the consumer's side). The library ships a shared C++ core plus AVFoundation (iOS) and Media3 Transformer (Android) adapters. Architecture deep-dive in [`docs/architecture.md`](./docs/architecture.md).

---

## Hard invariants (do not violate)

1. **Yarn only.** Yarn 4 (Berry) with `nodeLinker: node-modules`. `yarn.lock` is committed. CI uses `yarn install --immutable`. Never `npm`, never `pnpm`, never PnP.
2. **Both iOS and Android are first-class.** No "platform is a stub" shortcuts.
3. **Zero Skia in the library.** Consumers bring `@shopify/react-native-skia` only for the compose worklet path. Skia stays in `peerDependenciesMeta`, never `dependencies` or `peerDependencies`.
4. **No FFmpeg, ever.** AVFoundation + Media3 Transformer only.
5. **Offline only.** No network calls. No realtime pacing. PTS is always `frameIndex / fps`.
6. **Nitro spec is the single source of truth.** `packages/react-native-video-pipeline/src/nitro/VideoPipeline.nitro.ts` declares every cross-boundary type. Never hand-edit generated files under `nitrogen/`.
7. **Type safety is non-negotiable.** Strict tsconfig (`noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, `noImplicitOverride`, `noFallthroughCasesInSwitch`). No `any` in the public API. Exhaustive discriminated unions via `assertNever`. No `@ts-ignore` / `@ts-expect-error` in `src/`.
8. **Worklet directive enforcement is build-time** (via `babel-plugin-video-pipeline`). No runtime fallback checks.
9. **Derived artifacts are gitignored.** `nitrogen/`, `packages/react-native-video-pipeline/plugin/build/`. `plugin/build/` ships via the npm tarball's `files` allowlist + `prepack`, not via git.
10. **Tests bootstrap their own fixtures** via `Video.synthesize`. No committed binary video files.
11. **Public API matches [`docs/api.md`](./docs/api.md) exactly.** Deviate only after that doc and the Nitro spec have been updated.

---

## Per-iteration verification (from repo root)

- `yarn lint` (Biome + ESLint-RN)
- `yarn format` (Biome formatter — must leave a clean tree)
- `yarn typecheck` (strict, zero suppressions)
- `yarn test` (where JS tests exist for the touched area)
- `yarn test:native` — **default for any change to `cpp/**` or `ios/**/*.{h,mm}`**. Compiles against `-sdk macosx` and runs XCTests directly on the host (~6s, no simulator). Covers AVMuxer, AVDemuxer, WorkletFrameBridge, SynthesizeRunner, Remuxer, ComposeRunner, StopToken — all remux / transcode / probe / thumbnail work.
- `yarn smoke:ios` — **only run when the task exercises the RN → Nitro → native bridge** (JS → Nitro → C++/Obj-C++ at runtime): changes to `src/video.ts`, `src/native.ts`, the Nitro spec, `VideoPipeline.mm`, or anything that needs Metro + Hermes + the HybridObject registry. Otherwise `yarn test:native` is sufficient and ~30× faster. This is what CI will run.
- iOS build (Pods + `xcodebuild`) and/or Android build (Gradle) when native code changed

CI is deliberately the last task — local verification is the gate throughout.

---

## Task workflow

1. Read `activity.md` (gitignored).
2. In `TODO.md` (gitignored), find the lowest-`priority` open task whose `depends_on` are all done.
3. Implement **exactly one** task per iteration.
4. Run the applicable checks above.
5. Append a dated entry to `activity.md` — what changed, what commands ran, issues + resolutions.
6. Move that task from "Open" to "Done" in `TODO.md`.
7. Commit on a topic branch (create from `main`), one commit per task, then open a PR against `main`. Never commit directly to `main`.

---

## See also

- `CLAUDE.md` — identical invariants; authoritative for Claude Code.
- [`docs/architecture.md`](./docs/architecture.md) — repo layout, tech stack, module inventory, locked-in design decisions.
- [`docs/api.md`](./docs/api.md) — public API reference.
- [`docs/examples/`](./docs/examples/) — runnable scenarios per operation.
- `CONTRIBUTING.md` — human-contributor dev setup + commit style.
