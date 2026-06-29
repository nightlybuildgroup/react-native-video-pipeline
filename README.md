<div align="center">

# 🎬 react-native-video-pipeline

### Offline video editing for React Native — without FFmpeg.

**Trim · Flip · Stamp · Compose · Synthesize · Probe** — on **iOS** and **Android**, fully offline, with a strict-TypeScript API.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![iOS 13+](https://img.shields.io/badge/iOS-13%2B-black.svg?logo=apple)](#requirements)
[![Android 24+](https://img.shields.io/badge/Android-API%2024%2B-3ddc84.svg?logo=android)](#requirements)
[![New Architecture](https://img.shields.io/badge/RN-New%20Architecture-61dafb.svg?logo=react)](#requirements)
[![Built with Nitro](https://img.shields.io/badge/built%20with-Nitro%20Modules-ff69b4.svg)](https://nitro.margelo.com)

</div>

---

## Why this exists

Every "edit a video on-device" path in React Native eventually hits the same wall: **`ffmpeg-kit-react-native` is retired**, and FFmpeg's codec/patent licensing makes shipping it in a commercial app a legal minefield.

`react-native-video-pipeline` is the answer that doesn't touch FFmpeg at all. It drives the **platform's own** media engines — **AVFoundation** on iOS and **Media3 Transformer** on Android — through a single shared C++ core and a tiny, strongly-typed JS surface built on [Nitro Modules](https://nitro.margelo.com).

| | `react-native-video-pipeline` | FFmpeg-based libs |
| --- | --- | --- |
| Licensing | ✅ MIT, no codec patents to worry about | ⚠️ GPL/LGPL + codec patent exposure |
| Engine | ✅ Native AVFoundation / Media3 | ❌ Bundled FFmpeg binary |
| Binary size | ✅ Thin — no media binary shipped | ❌ Tens of MB per ABI |
| Maintenance | ✅ Actively developed | ❌ `ffmpeg-kit` is **retired** |
| Network | ✅ 100% offline, zero network calls | varies |
| Type safety | ✅ Strict TS, no `any`, exhaustive unions | varies |

---

## Highlights

- 🚀 **Three execution paths, picked for you.** *Remux* (passthrough copy — no re-encode), *transcode* (native hot loop with native overlays), and *compose* (per-frame worklet drawing). The cheapest path that satisfies your spec is selected automatically.
- 🪶 **Skia-free by default.** The library never imports Skia. Static image/text overlays use `CIFilter` + `CATextLayer` (iOS) and Media3 `BitmapOverlay` + `TextOverlay` (Android). Skia is an *optional* peer you only pull in for the per-frame `compose` worklet path.
- ✍️ **Draw your own frames.** `Video.compose` and `Video.synthesize` hand a worklet a live pixel buffer per frame — fill raw RGBA, or reach zero-copy Skia (with a Metal blit fast path on iOS).
- 🔒 **Strict TypeScript surface.** `strict` + `noUncheckedIndexedAccess` + `exactOptionalPropertyTypes`. Discriminated unions for overlays, durations, audio, and errors — with compile-time exhaustiveness. No `any` in the public API.
- ⏱️ **Deterministic & offline.** Output PTS is always `frameIndex / fps`, never wall-clock. No network, no realtime pacing.
- 📦 **Cancellation & progress.** `AbortSignal`, a graceful `VideoRenderController.finish()`, and `onProgress` callbacks on the transcode/compose paths.
- 🧩 **Expo-friendly.** Ships an Expo config plugin in the same package.

---

## Requirements

- **iOS 13+** (AVFoundation) · **Android API 24+** (Media3 Transformer)
- **React Native New Architecture only** (Nitro Modules + Hermes)
- Yarn 4 (Berry) if you're working *in* this repo — see [`CLAUDE.md`](./CLAUDE.md)

---

## Install

> **Status: pre-1.0, not yet published to npm.** The API is stabilizing toward v1 and may still shift. Install from GitHub today:

```sh
yarn add github:nightlybuildgroup/react-native-video-pipeline
yarn add react-native-nitro-modules react-native-worklets-core
yarn add -D babel-plugin-video-pipeline
```

`react-native-nitro-modules` and `react-native-worklets-core` are required peer dependencies. `@shopify/react-native-skia` and `react-native-reanimated` are **optional** peers — only consumers of the worklet `compose` / `synthesize` path need them.

Then add the build-time worklet check to `babel.config.js`:

```js
// babel.config.js
module.exports = {
  presets: ['module:@react-native/babel-preset'],
  plugins: [
    'babel-plugin-video-pipeline',
    'react-native-reanimated/plugin', // must come after
  ],
};
```

This fails the bundle if a `drawFrame` worklet is missing its `'worklet';` directive — turning a cryptic first-frame runtime crash into a clear build error.

---

## Quickstart

The whole library is a single `Video` namespace plus an `Overlay` builder. Every operation writes to an output `path` you supply.

### Trim — remux, no re-encode (fastest)

```ts
import { Video } from 'react-native-video-pipeline';

await Video.trim(sourceUri, {
  outPath: `${dir}/trimmed.mp4`,
  startSec: 2,
  durationSec: 5,
});
```

### Stamp — watermark + metadata

```ts
import { Video, Overlay } from 'react-native-video-pipeline';

await Video.stamp(sourceUri, {
  outPath: `${dir}/stamped.mp4`,
  watermark: Overlay.Image({ uri: logoUri, anchor: 'br', size: { width: { unit: 'ratio', value: 0.2 } } }),
  metadata: { software: 'MyApp 1.4', creationDate: new Date() },
});
```

### Render — concat clips, multiple overlays, custom encode (one pass)

```ts
import { Video, Overlay } from 'react-native-video-pipeline';

await Video.render({
  clips: [
    { uri: 'intro.mp4', startSec: 0, durationSec: 2 },
    { uri: 'main.mp4', startSec: 5, durationSec: 30 },
    { uri: 'outro.mp4', startSec: 0, durationSec: 3 },
  ],
  overlays: [
    Overlay.Image({ uri: 'logo.png', anchor: 'tl', size: { width: { unit: 'ratio', value: 0.15 } } }),
    Overlay.Text({ text: '@username', anchor: 'br', style: { fontSize: 24, color: '#fff' } }),
  ],
  audio: { mode: 'replace', replaceUri: 'soundtrack.m4a' },
  output: { path: `${dir}/out.mp4`, width: 1920, height: 1080, fps: 30, codec: 'h264', bitrate: 8_000_000 },
});
```

One `render` call decodes and encodes exactly **once** — no lossy temp-file round-trips between steps.

### Synthesize — generate frames from scratch (worklet)

```ts
import { Video, drawWithRGBA } from 'react-native-video-pipeline';

await Video.synthesize({
  output: { path: `${dir}/synth.mp4`, width: 320, height: 240, fps: 30 },
  duration: { mode: 'fixed', seconds: 2 },
  drawFrame: drawWithRGBA((pixels, ctx) => {
    'worklet';
    for (let i = 0; i < pixels.length; i += 4) {
      pixels[i] = (ctx.frameIndex * 4) & 0xff; // R ramps over time
      pixels[i + 1] = 128;                     // G
      pixels[i + 2] = 255;                     // B
      pixels[i + 3] = 255;                     // A
    }
  }),
});
```

`Video.compose` is the same idea, but your worklet draws *on top of* source clips. For zero-copy Skia drawing, see [`docs/examples/compose-skia.md`](./docs/examples/compose-skia.md).

### Probe — read metadata

```ts
const info = await Video.info(sourceUri);
// { width, height, fps, durationSec, codec, container, hasAudio, isHDR, rotation, ... }
```

---

## At a glance

| Method | Does | Path |
| --- | --- | --- |
| `Video.info` / `Video.thumbnail` / `Video.capabilities` | Probe metadata, extract a frame, query encoder caps | — |
| `Video.trim` | Lossless-cut a single clip (no transform — use `render` to also transform) | remux |
| `Video.flip` | Horizontal / vertical flip | remux → transcode |
| `Video.stamp` | Watermark and/or write metadata | remux (metadata) / transcode (watermark) |
| `Video.render` | Multi-clip concat, overlays, custom encode, audio | remux / transcode |
| `Video.compose` | Per-frame worklet drawing over source clips | compose |
| `Video.synthesize` | Per-frame worklet drawing from scratch | compose |

Full decision tree and every type in the **[API reference »](./docs/api.md)**

---

## How it works

```
                    ┌──────────────────────────────────────┐
   JS / TypeScript  │  Video.*  ·  Overlay.*  ·  drawWith*  │
                    └──────────────────┬───────────────────┘
                          Nitro spec (single source of truth)
                    ┌──────────────────┴───────────────────┐
   Shared C++ core  │  routing · stop tokens · frame pump   │
                    └────────┬───────────────────┬──────────┘
                       iOS   │                   │   Android
                 AVFoundation┤                   ├ Media3 Transformer
                   CIFilter  │                   │  Bitmap/TextOverlay
                CVPixelBuffer │                   │  AHardwareBuffer
                    └─────────┘                   └──────────┘
```

A single Nitro spec generates the JS, C++, Objective-C++, and Kotlin bindings, so the cross-boundary types can never drift. Deep dives:

- **[Architecture »](./docs/architecture.md)** — repo layout, tech stack, locked-in decisions
- **[Rendering — iOS »](./docs/rendering-ios.md)** — how the three iOS paths share `CVPixelBuffer`
- **[Rendering — Android »](./docs/rendering-android.md)** — Media3 + AHardwareBuffer, Y-flip discipline

---

## Packages

This is a Yarn workspaces monorepo. The consumable library lives at [`packages/react-native-video-pipeline/`](./packages/react-native-video-pipeline/).

| Package | Purpose |
| --- | --- |
| [`react-native-video-pipeline`](./packages/react-native-video-pipeline/) | Main library + Expo config plugin. |
| [`babel-plugin-video-pipeline`](./packages/babel-plugin-video-pipeline/) | Build-time enforcement of `'worklet';` directives on `drawFrame`. |
| [`react-native-video-pipeline-skia`](./packages/react-native-video-pipeline-skia/) | Optional consumer-side `drawWithSkia` helper (keeps the core Skia-free). |
| `apps/bare-example`, `apps/expo-example` | Runnable consumer apps for local verification. |

---

## Documentation

- 📘 **[API reference](./docs/api.md)** — every export, type, and error code
- 🧪 **[Examples](./docs/examples/)** — one runnable scenario per file (trim, flip, stamp, compose, synthesize, probe, cancel/finish)
- 🏗️ **[Architecture](./docs/architecture.md)** · **[iOS rendering](./docs/rendering-ios.md)** · **[Android rendering](./docs/rendering-android.md)**

---

## Contributing

Contributions welcome. Start with [`CONTRIBUTING.md`](./CONTRIBUTING.md) for dev setup and commit style, and [`CLAUDE.md`](./CLAUDE.md) / [`AGENTS.md`](./AGENTS.md) for the load-bearing invariants any change must respect (yarn-only, no FFmpeg, no Skia in the core, offline-only, the Nitro spec as single source of truth).

## License

[MIT](./LICENSE) © contributors
