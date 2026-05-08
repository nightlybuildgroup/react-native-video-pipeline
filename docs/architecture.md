# Architecture

This document describes how `react-native-video-pipeline` is organized internally. For the public API see [`api.md`](./api.md); for runnable scenarios see [`examples/`](./examples/); for the platform-specific render pipelines see [`rendering-ios.md`](./rendering-ios.md) and [`rendering-android.md`](./rendering-android.md).

## Contents

- [Tech stack](#tech-stack)
- [Repo layout](#repo-layout)
- [Library modules](#library-modules)
- [State](#state)
- [Locked-in design decisions](#locked-in-design-decisions)
- [Known limitations](#known-limitations)
- [Tradeoffs](#tradeoffs)

---

## Tech stack

| Layer                   | Choice                                                                                       | Why                                                                                                          |
| ----------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Binding                 | **Nitro Modules**                                                                            | Codegen, typed, zero-overhead JSI; no hand-rolled `HostObject`s                                              |
| Core language           | **C++17**                                                                                    | Shared engine across iOS/Android; matches Skia's native API                                                  |
| iOS adapter             | **Objective-C++**                                                                            | AVFoundation interop                                                                                         |
| Android adapter         | **Kotlin**                                                                                   | Media3 Transformer is Java/Kotlin-first                                                                      |
| iOS framework           | **AVFoundation + AVAssetWriter + CoreImage**                                                 | Native, hardware-accelerated, no patent risk                                                                 |
| Android framework       | **Media3 Transformer + MediaCodec**                                                          | Google-maintained, Jetpack-blessed; closes the Media3 gap that killed the previous Android stub             |
| Image overlay (static)  | **CIFilter** + `AVMutableVideoComposition` (iOS) / Media3 `OverlayEffect` + `BitmapOverlay` (Android) | No Skia dep; both platforms have first-class bitmap-overlay primitives; pixel-hash parity is achievable     |
| Text overlay (static)   | **CATextLayer** (iOS) / Media3 `TextOverlay` (Android)                                       | No Skia dep; minimal declarative API; cross-platform parity is "visually similar," not pixel-identical      |
| Worklet runtime         | **react-native-worklets-core** (peer)                                                        | Standard RN way to run JS off the JS thread                                                                  |
| Dynamic overlay drawing | **@shopify/react-native-skia** (optional peer, compose path only)                            | Consumer brings Skia; library never imports it                                                               |
| Build                   | **react-native-builder-bob + Nitro codegen**                                                 | Standard RN lib toolchain                                                                                    |
| Package manager         | **Yarn 4 (Berry)**, `nodeLinker: node-modules`                                               | Modern Yarn with workspace support; node-modules linker because CocoaPods/Gradle/Nitro need a real `node_modules/` |
| Worklet static analysis | **Custom Babel plugin** (`babel-plugin-video-pipeline`)                                      | Build-time check that every `FrameDrawer` callsite carries `'worklet';`; eliminates first-frame crashes     |
| Type checking           | **`tsc --strict`** + `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`                | Blocks `any`, enforces exhaustive unions, catches mistakes at `yarn typecheck` time                          |
| Lint + format (primary) | **Biome**                                                                                    | Single fast tool for lint and format; covers most of what we need in one config                              |
| Lint (transitional)     | **ESLint** + `eslint-plugin-react-native`                                                    | Retained only for RN-specific rules Biome doesn't yet cover                                                  |
| JS tests                | **Jest** + `@testing-library/react-native`                                                   | Standard RN lib choice                                                                                       |
| Native tests            | **XCTest** (iOS) / **JUnit** (Android)                                                       | Platform-native module tests                                                                                 |
| Native E2E              | **Maestro**                                                                                  | Simple YAML flows; works on both iOS simulator and Android emulator                                          |
| Pixel parity            | **Golden-file hash suite**                                                                   | Deterministic hash of sampled frames; iOS vs Android vs reference                                            |
| CI                      | **GitHub Actions**                                                                           | Build iOS sim + Android emulator; run golden-file tests                                                      |
| License                 | **MIT**                                                                                      | Max compatibility with the RN ecosystem                                                                      |

---

## Repo layout

Yarn-workspaces monorepo. Two publishable packages plus non-publishable example apps and infra.

```
react-native-video-pipeline/                          # repo root (yarn workspaces)
├── package.json                                      # workspace root; "packageManager" pinned; private: true
├── yarn.lock                                         # committed
├── tsconfig.base.json                                # strict + noUncheckedIndexedAccess + exactOptionalPropertyTypes
├── .gitignore                                        # nitrogen/, plugin/build/, build/, etc.
│
├── packages/                                         # publishable
│   ├── react-native-video-pipeline/                  # main library + Expo config plugin (same package)
│   │   ├── package.json                              # peer: react-native, react-native-nitro-modules, react-native-worklets-core
│   │   │                                             # optional peer: @shopify/react-native-skia, react-native-reanimated, expo
│   │   ├── src/                                      # TypeScript public API
│   │   │   ├── index.ts                              # Video / Overlay / drawWithRGBA exports
│   │   │   ├── video.ts                              # Video.info / trim / flip / stamp / render / compose / synthesize
│   │   │   ├── errors.ts                             # VideoPipelineError + subclasses
│   │   │   ├── overlay.ts                            # Overlay.Image / .Text / .Worklet builders
│   │   │   ├── controller.ts                         # VideoRenderController (finish / abort)
│   │   │   ├── drawWithRGBA.ts                       # plain-pixel worklet helper (no Skia)
│   │   │   ├── bootstrap-pattern.ts                  # deterministic test pattern (US13 fixture bootstrap)
│   │   │   └── nitro/
│   │   │       └── VideoPipeline.nitro.ts            # SINGLE SOURCE OF TRUTH for all cross-boundary types
│   │   ├── nitrogen/                                 # generated — gitignored
│   │   ├── cpp/                                      # shared C++ engine (no Skia)
│   │   │   ├── engine/                               # Router, Timeline, SpecValidator
│   │   │   ├── remux/                                # Remuxer (passthrough)
│   │   │   ├── transcode/                            # Transcoder (native hot loop)
│   │   │   ├── compose/                              # ComposeRunner (worklet per-frame)
│   │   │   └── audio/                                # AudioPipeline
│   │   ├── ios/                                      # AVFoundation adapter
│   │   │   ├── VideoPipeline.mm                      # Nitro adapter
│   │   │   ├── AVDemuxer.mm / AVMuxer.mm
│   │   │   ├── OverlayRenderer.mm                    # CIFilter + CATextLayer
│   │   │   ├── WorkletFrameBridge.mm                 # CVPixelBuffer ↔ consumer Skia (compose path)
│   │   │   └── BackgroundTaskGuard.mm
│   │   ├── android/                                  # Media3 adapter
│   │   │   └── src/main/java/com/videopipeline/
│   │   │       ├── VideoPipelineModule.kt
│   │   │       ├── Media3Transcoder.kt / Media3Remuxer.kt
│   │   │       ├── OverlayRenderer.kt                # Media3 BitmapOverlay + TextOverlay
│   │   │       ├── WorkletFrameBridge.kt             # AHardwareBuffer ↔ consumer Skia
│   │   │       └── ForegroundExportService.kt
│   │   └── plugin/                                   # Expo config plugin (bundled here so Expo's resolver finds it)
│   │       ├── src/index.ts
│   │       └── build/                                # generated by `yarn prepack`; gitignored; shipped via "files"
│   │
│   ├── babel-plugin-video-pipeline/                  # build-time worklet directive enforcer
│   │   ├── package.json
│   │   ├── src/
│   │   │   ├── index.ts                              # plugin entry
│   │   │   └── rules/require-worklet-directive.ts
│   │   └── __tests__/
│   │
│   └── react-native-video-pipeline-skia/             # consumer-side Skia helper (drawWithSkia)
│       └── src/                                      # wraps Skia surface + readPixels/writeBytes
│
├── apps/                                             # non-publishable; "private": true
│   ├── bare-example/                                 # bare RN consumer
│   └── expo-example/                                 # Expo consumer (exercises the config plugin)
│
├── __tests__/                                        # cross-package integration + E2E
│   ├── bootstrap/                                    # US13 — Video.synthesize generates input fixtures
│   ├── unit/                                         # JS-only
│   └── golden/                                       # cross-platform pixel-hash references
│       ├── ios/*.hash
│       └── android/*.hash
│
├── docs/                                             # markdown docs hosted on GitHub
│   ├── api.md
│   ├── architecture.md                               # this file
│   ├── examples/
│   ├── rendering-ios.md
│   └── rendering-android.md
├── .github/workflows/                                # CI: iOS + Android build + golden tests
├── CLAUDE.md / AGENTS.md                             # invariants for coding agents
├── CONTRIBUTING.md
├── LICENSE                                           # MIT
└── README.md
```

### Derived artifacts

`nitrogen/` and `packages/react-native-video-pipeline/plugin/build/` are gitignored and regenerated. `plugin/build/` ships in the npm tarball via the `files` allowlist + a `prepack` script — not via git. The GitHub tree stays source-only; the npm artifact is ready-to-use.

---

## Library modules

| Module                   | Type                              | Description                                                                                                                              |
| ------------------------ | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `Video.info`             | Probe                             | Read dimensions, duration, fps, codec, HDR, bit rate, container metadata                                                                 |
| `Video.thumbnail`        | Probe                             | Extract JPEG at offset, optional resize                                                                                                  |
| `Video.capabilities`     | Probe                             | Report device encoder caps (max res/fps/codec, HDR support)                                                                              |
| `Video.trim`             | Convenience → remux               | Time-range trim, passthrough; transcodes when transform has crop/flip                                                                    |
| `Video.flip`             | Convenience → remux/transcode     | Rotation-flag flip in mp4/mov; transcodes otherwise                                                                                      |
| `Video.stamp`            | Convenience → transcode/remux     | Watermark + metadata; metadata-only stamps remux                                                                                         |
| `Video.render`           | Core                              | Accepts `VideoSpec`, auto-routes to remux / transcode / compose                                                                          |
| `Video.compose`          | Convenience → compose             | Sugar over `render` with a `drawFrame` worklet                                                                                           |
| `Video.synthesize`       | Convenience → compose (null-input) | Sugar for zero-clip specs: render from a `drawFrame` worklet, with fixed or open-ended duration                                          |
| `VideoRenderController`  | Control surface                   | `abort()` (discard) + `finish()` (graceful) + progress observable                                                                        |
| `Overlay.Image`          | Spec primitive                    | Static image overlay; rendered natively via CIFilter (iOS) / Media3 `BitmapOverlay` (Android). Pixel-hash-parity target across platforms. |
| `Overlay.Text`           | Spec primitive                    | Static text overlay; rendered via CATextLayer / Media3 `TextOverlay`. **Visually similar, not pixel-identical** across platforms.        |
| `Overlay.Worklet`        | Spec primitive                    | Worklet escape hatch; consumer brings `@shopify/react-native-skia`. Only path that can achieve pixel-identical custom text.              |
| `drawWithRGBA`           | Worklet helper                    | Plain `(pixels, ctx) => void` callback; allocates a `Uint8Array`, swizzles to BGRA on iOS                                                |
| `Errors.*`               | Error types                       | `UnsupportedCodec`, `DeviceCapabilityExceeded`, `SourceCorrupted`, `Cancelled`, `IOError`, `EncoderFailure`, `InvalidSpec`               |
| `expo-plugin`            | Config plugin                     | Adds iOS Info.plist keys, Android permissions, Podfile/Gradle tweaks during `expo prebuild`                                              |

---

## State

| State                     | Location                       | Persistence                          | Notes                                              |
| ------------------------- | ------------------------------ | ------------------------------------ | -------------------------------------------------- |
| Active render handles     | Native (C++ engine)            | Session                              | Tracked for cancel + lifecycle                     |
| Progress counters         | Native, pushed to JS ≥ 10 Hz   | Ephemeral                            | Coalesced on the native side                       |
| `AbortSignal` subscription | JS (Nitro binding)            | Ephemeral                            | Releases native resources on abort                 |
| Encoder capabilities cache | Native, in-process            | Session                              | Invalidated on device orientation/config change    |
| Logger callback           | JS                             | Session                              | Passed via `setLogger`                             |
| Expo plugin state         | Build-time (prebuild)          | Persistent in native configs         | Idempotent                                         |

---

## Locked-in design decisions

These are decisions that have been made and should not be re-litigated without a strong reason.

- **Pacing — no realtime mode.** The library is strictly offline; the encoder advances at whatever speed the hardware delivers, PTS is always `frameIndex / fps`. No `options.pacing: 'accurate' | 'realtime'` knob.
- **Worklet directive enforcement — Babel plugin, build-time only.** No runtime fallback. Applies uniformly to `Video.compose`, `Video.synthesize`, and `Overlay.Worklet`. Published as a separate workspace package `babel-plugin-video-pipeline`.
- **Wall-clock exposure to worklets — yes.** `ctx.elapsedMs` is part of `FrameDrawerContext`. Useful for open-ended renders that want a "stop after N real seconds" rule independent of output fps.
- **Skia — zero in the library.** Neither C++ nor JS. Static image/text overlays use platform-native primitives (CIFilter / CATextLayer on iOS, Media3 `BitmapOverlay` / `TextOverlay` on Android). Skia enters only when a consumer opts into the compose worklet path and brings in `@shopify/react-native-skia` themselves.
- **Pixel-hash parity scope.** Remux, transcode, and image-overlay paths target ≥ 99% cross-platform pixel-hash match. Text overlays and worklet content are explicitly out of scope — platform text shaping differs and no library-level fix is worth the cost.
- **Pixel-identical custom text — no dedicated helper.** Users who need it rasterize text to a PNG via Skia (≈ 5 lines) and pass the result as `Overlay.Image`. Shipped as a docs recipe, not code.
- **Package manager — Yarn 4 (Berry) workspaces with `nodeLinker: node-modules`.** PnP not used. `yarn.lock` committed, `packageManager` pinned in root `package.json` (installed via Corepack), CI uses `yarn install --immutable`.
- **Lint + format — Biome primary.** ESLint + `eslint-plugin-react-native` retained transitionally for RN-specific rules Biome doesn't yet cover.
- **Test stack.** Jest + `@testing-library/react-native` for JS; XCTest / JUnit for native units; Maestro for native E2E; golden-file pixel-hash suite for cross-platform parity.
- **Monorepo layout.** Two publishable packages (`react-native-video-pipeline`, `babel-plugin-video-pipeline`) under `packages/`; example apps under `apps/`; the Expo config plugin lives **inside** the main package (Expo's plugin resolution expects this).
- **Derived artifacts.** `nitrogen/` and `plugin/build/` are gitignored. `plugin/build/` is generated by `yarn prepack` and shipped in the npm tarball via the `files` field — so the GitHub tree is source-only while the npm artifact is ready-to-use.
- **Public API matches `docs/api.md` exactly.** Deviate only after this doc and the Nitro spec have been updated.

---

## Known limitations

- **iOS / Android text rendering is not pixel-identical.** `CATextLayer` vs Media3 `TextOverlay` differ in shaping, hinting, and kerning. `Overlay.Text` targets "visually similar," not "pixel-identical." Documented in [`api.md`](./api.md). Users who need identical text rasterize via Skia and pass as `Overlay.Image`.
- **Media3 Transformer is still evolving.** We pin to a specific Media3 version and maintain a compatibility matrix; the codebase falls back to MediaCodec directly for hot paths.
- **HDR re-encode on the transcode path can silently downgrade to SDR.** Mitigated by an explicit `hdr: 'preserve' | 'downgrade' | 'error'` option on `OutputSpec`; default is `error` so accidents are loud.
- **Nitro Modules is < 1.0.** We pin the Nitro version; we'll contribute upstream if blockers appear.
- **Per-frame worklet crashes are hard to debug for consumers.** Every frame call is wrapped in a native try/catch; the first failure surfaces with `currentTime` + stack in the error.
- **Null-input / open-ended renders are the most error-prone code path.** No input stream to drive timing, JS controls lifecycle, easy to hang forever. Mitigated by requiring at least one stop mechanism (`maxSeconds`, `AbortSignal`, or `VideoRenderController`) at spec-validation time.
- **Bootstrapping tests from synthesized output creates a circular dependency.** A bug in `synthesize` masks bugs everywhere else. Mitigated by a tiny built-in self-test (pixel-hash known values of a deterministic pattern) that runs before the rest of the suite — see `bootstrap-pattern.ts`.

---

## Tradeoffs

- **No FFmpeg.** Avoids the patent/license minefield that killed `ffmpeg-kit-react-native`, at the cost of some esoteric codec support (ProRes, AV1 encode on older Android). Acceptable — 99% of RN video needs are H.264 / HEVC.
- **New Architecture only.** Cuts out apps that haven't migrated. By late 2026 this is a small minority; the alternative (two binding layers) isn't worth the cost.
- **No raw `drawFrame` on the transcode path.** Consumers who want a "cheap dynamic overlay that changes once" must either accept re-draws per frame (compose) or pre-rasterize to a `Picture` and pass it as `Overlay.Image`. This simplifies the mental model.
