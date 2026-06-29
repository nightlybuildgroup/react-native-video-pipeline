# react-native-video-pipeline

Offline video editing for React Native (iOS + Android) built on Nitro Modules. Trim, flip, stamp, compose, synthesize, and probe — no FFmpeg, no network, no realtime pacing.

> **Status:** v0.4.x (pre-1.0). Trim, flip, stamp, compose, synthesize, and probe all work on iOS and Android. The public API may still change before 1.0.

- **iOS 13+** via AVFoundation
- **Android API 24+** via Media3 Transformer
- **New Architecture only** (Nitro Modules + Hermes)
- **Strict TypeScript** public surface — discriminated unions, no `any`
- **Optional Skia** — only if you reach for the `compose` worklet path

## Install

```sh
yarn add react-native-video-pipeline react-native-nitro-modules react-native-worklets-core
```

`react-native-nitro-modules` and `react-native-worklets-core` are required peer dependencies. `@shopify/react-native-skia` is an optional peer — only the Skia compose path (`drawWithSkia`) needs it. You do **not** need `react-native-reanimated`; see the [build-time worklet lint](#setup-babel-plugin-video-pipeline-optional-build-time-lint) note below. To read and write files you also need a filesystem library — see [Filesystem paths](#filesystem-paths).

## Quickstart

The library exposes a single `Video` namespace plus an `Overlay` builder. Every operation writes to an `outPath` you supply.

### Filesystem paths

The examples below read a `sourceUri` / `logoUri` and write to `` `${dir}/out.mp4` ``. React Native core ships **no** API for a writable directory or for picking a source file, so bring a filesystem library and derive the paths yourself — e.g. [`@dr.pogodin/react-native-fs`](https://github.com/birdofpreyru/react-native-fs) (bare RN) or [`expo-file-system`](https://docs.expo.dev/versions/latest/sdk/filesystem/) (Expo):

```ts
import { TemporaryDirectoryPath } from '@dr.pogodin/react-native-fs';

const dir = TemporaryDirectoryPath;            // a writable directory
const sourceUri = `file://${dir}/input.mp4`;   // a file your app downloaded/recorded
```

All `outPath` and `uri` values are plain filesystem paths or `file://` URIs.

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

## Setup: babel-plugin-video-pipeline (optional, build-time lint)

`Video.compose` and `Video.synthesize` take a `drawFrame` callback that must begin with a `'worklet';` directive. **Today that directive is enforced at build time only** — `drawFrame` currently runs on the JS thread ([#34](https://github.com/nightlybuildgroup/react-native-video-pipeline/issues/34)), so you do **not** need `react-native-reanimated` or any worklet babel transform to run the compose / synthesize examples; the default React Native preset is enough (that's exactly what `apps/bare-example` uses). The directive is required so consumer code is ready for the planned move to a dedicated worklet runtime.

`babel-plugin-video-pipeline` is an optional build-time lint that catches a missing directive before it bites: it fails the bundle if an inline function passed as `drawFrame` to `Video.compose` / `Video.synthesize` doesn't start with `'worklet';`. To enable it:

```sh
yarn add -D babel-plugin-video-pipeline
```

```js
// babel.config.js
module.exports = {
  presets: ['module:@react-native/babel-preset'],
  plugins: [
    'babel-plugin-video-pipeline',
    // If you also use Reanimated for your own reasons, its plugin must come last:
    // 'react-native-reanimated/plugin',
  ],
};
```

The plugin only inspects inline function literals; passing a named identifier (e.g. `drawFrame: myDrawer`) is allowed. The library never runs the directive check at runtime — the guarantee is entirely build-time.

## Docs

- **[API reference](../../docs/api.md)** — every export, every type, every error code
- **[Examples](../../docs/examples/)** — one runnable scenario per file (trim, flip, stamp, compose, synthesize, probe)
- **[Rendering — iOS](../../docs/rendering-ios.md)** — how the three iOS render paths share `CVPixelBuffer`
- **[Rendering — Android](../../docs/rendering-android.md)** — Media3 + AHardwareBuffer pipeline and Y-flip discipline

The `apps/bare-example` workspace in this repo is a runnable consumer app covering each path. The package also ships an Expo config plugin (`app.plugin.js`), so it works in Expo prebuild projects; a dedicated `apps/expo-example` app is not in the repo yet ([#71](https://github.com/nightlybuildgroup/react-native-video-pipeline/issues/71)).

## Invariants

- **yarn only** (Yarn 4 Berry, `nodeLinker: node-modules`). Never `npm` or `pnpm`.
- **Both iOS and Android** are first-class — no platform stubs.
- **Zero Skia in the library itself** — consumers bring `@shopify/react-native-skia` for the compose worklet path.
- **No FFmpeg**, ever — AVFoundation + Media3 Transformer only.
- **Offline only** — no realtime pacing, no network calls.
- **Type safety:** strict TS, no `any` in the public API, exhaustive discriminated unions.

## License

[MIT](../../LICENSE).
