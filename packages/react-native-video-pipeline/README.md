# react-native-video-pipeline

Offline video editing for React Native (iOS + Android) built on Nitro Modules. Trim, flip, stamp, compose, synthesize, and probe — no FFmpeg, no network, no realtime pacing.

> **Status:** pre-alpha (v0.1 scaffolding). API may change before the first tagged release.

- **iOS 13+** via AVFoundation
- **Android API 24+** via Media3 Transformer
- **New Architecture only** (Nitro Modules + Hermes)
- **Strict TypeScript** public surface — discriminated unions, no `any`
- **Optional Skia** — only if you reach for the `compose` worklet path

## Install

```sh
yarn add react-native-video-pipeline react-native-nitro-modules react-native-worklets-core
yarn add -D babel-plugin-video-pipeline
```

`react-native-nitro-modules` and `react-native-worklets-core` are required peer dependencies. `@shopify/react-native-skia` and `react-native-reanimated` are optional peers — only consumers of the worklet `compose` / `synthesize` path need them.

## Quickstart

The library exposes a single `Video` namespace plus an `Overlay` builder. Every operation writes to an `outPath` you supply.

### Remux — trim without re-encoding

```ts
import { Video } from 'react-native-video-pipeline';

await Video.trim(sourceUri, {
  outPath: `${dir}/trimmed.mp4`,
  startSec: 2,
  durationSec: 5,
});
```

### Transcode — stamp a watermark and metadata

```ts
import { Video, Overlay } from 'react-native-video-pipeline';

await Video.stamp(sourceUri, {
  outPath: `${dir}/stamped.mp4`,
  watermark: Overlay.Image({
    uri: logoUri,
    anchor: 'br',
    size: { width: { unit: 'ratio', value: 0.2 } }, // 20% of output width
  }),
  metadata: { software: 'MyApp 1.4', creationDate: new Date() },
});
```

### Compose / Synthesize — per-frame worklet drawing

The worklet path is the only one that pulls in Skia, and only on the consumer side. The simplest entry point uses `drawWithRGBA`, which hands you a plain `Uint8Array` to fill:

```ts
import { Video, drawWithRGBA } from 'react-native-video-pipeline';

await Video.synthesize({
  output: { path: `${dir}/synth.mp4`, width: 320, height: 240, fps: 30 },
  duration: { mode: 'fixed', seconds: 2 },
  drawFrame: drawWithRGBA((pixels, ctx) => {
    'worklet';
    for (let i = 0; i < pixels.length; i += 4) {
      pixels[i] = (ctx.frameIndex * 4) & 0xff;
      pixels[i + 1] = 128;
      pixels[i + 2] = 255;
      pixels[i + 3] = 255;
    }
  }),
});
```

For zero-copy Skia drawing, see [`docs/examples/compose-skia.md`](../../docs/examples/compose-skia.md).

### Probe — read codec and dimensions

```ts
import { Video } from 'react-native-video-pipeline';

const info = await Video.info(sourceUri);
// { width, height, fps, durationSec, codec, container, hasAudio, isHDR, ... }
```

## Setup: babel-plugin-video-pipeline (strongly recommended)

`Video.compose` and `Video.synthesize` accept a `drawFrame` callback that runs on the Reanimated UI runtime. Reanimated requires every such function to begin with a `'worklet';` directive so it can be serialized onto the UI thread. Forgetting the directive produces a runtime crash on the first frame with an error that's hard to trace back to the call site.

`babel-plugin-video-pipeline` catches this at build time. Add it to your `babel.config.js`:

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

The plugin inspects any inline function literal passed as `drawFrame` to `Video.compose` / `Video.synthesize` and fails the bundle if the function body does not start with `'worklet';`. Passing a named identifier (e.g. `drawFrame: myDrawer`) is allowed — the plugin only checks inline literals. The library never runs the directive check at runtime; the guarantee is entirely build-time.

## Docs

- **[API reference](../../docs/api.md)** — every export, every type, every error code
- **[Examples](../../docs/examples/)** — one runnable scenario per file (trim, flip, stamp, compose, synthesize, probe)
- **[Rendering — iOS](../../docs/rendering-ios.md)** — how the three iOS render paths share `CVPixelBuffer`
- **[Rendering — Android](../../docs/rendering-android.md)** — Media3 + AHardwareBuffer pipeline and Y-flip discipline

The `apps/bare-example` and `apps/expo-example` workspaces in this repo are runnable consumer apps for each path.

## Invariants

- **yarn only** (Yarn 4 Berry, `nodeLinker: node-modules`). Never `npm` or `pnpm`.
- **Both iOS and Android** are first-class — no platform stubs.
- **Zero Skia in the library itself** — consumers bring `@shopify/react-native-skia` for the compose worklet path.
- **No FFmpeg**, ever — AVFoundation + Media3 Transformer only.
- **Offline only** — no realtime pacing, no network calls.
- **Type safety:** strict TS, no `any` in the public API, exhaustive discriminated unions.

## License

[MIT](../../LICENSE).
