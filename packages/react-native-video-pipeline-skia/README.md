# react-native-video-pipeline-skia

Skia drawing helper for [`react-native-video-pipeline`](https://www.npmjs.com/package/react-native-video-pipeline). Wraps the offscreen-surface + `readPixels`/`writeBytes` boilerplate of the `compose`/`synthesize` worklet path into a single `drawWithSkia()` callback, so your per-frame code stays a few lines.

This package is **optional and consumer-side only**. The main library has **zero** Skia dependency by design — Skia enters the picture only when you opt into worklet-driven per-frame drawing and bring Skia yourself.

## Install

```sh
yarn add react-native-video-pipeline-skia
```

### Peer dependencies

You must already have these in your app:

- `react-native-video-pipeline` — the main library
- `@shopify/react-native-skia` (>= 2) — the Skia runtime you bring
- `react-native-worklets-core` — the worklet runtime

## Usage

`drawWithSkia` adapts a Skia drawing callback into a `FrameDrawer` you pass to `Video.compose` or `Video.synthesize`. The callback **must be a worklet** (`react-native-video-pipeline` enforces the `'worklet';` directive at build time via [`babel-plugin-video-pipeline`](https://www.npmjs.com/package/babel-plugin-video-pipeline)).

```ts
import { Skia } from '@shopify/react-native-skia';
import { Video } from 'react-native-video-pipeline';
import { drawWithSkia } from 'react-native-video-pipeline-skia';

await Video.synthesize({
  output: { path: `${dir}/synth.mp4`, width: 1080, height: 1920, fps: 30 },
  duration: { mode: 'fixed', seconds: 3 },
  drawFrame: drawWithSkia((canvas, ctx) => {
    'worklet';
    const paint = Skia.Paint();
    paint.setColor(Skia.Color('tomato'));
    canvas.drawCircle(ctx.width / 2, ctx.height / 2, 120, paint);
  }),
});
```

When the frame has a source image (`compose` over a clip), it is drawn at `(0, 0)` before your callback runs, so you layer on top of it.

### Backends

The helper feature-detects per frame and picks the fastest path available:

- **GPU fast path (iOS):** when Skia exposes a usable native texture pointer, the native pump blits Skia's backing texture straight into the encoder's `CVPixelBuffer` — no CPU readback.
- **CPU readback path (any platform):** `makeImageSnapshot()` → `readPixels()` → `target.writeBytes(...)`. Stable and portable; used whenever the GPU path is unavailable.

## License

MIT
