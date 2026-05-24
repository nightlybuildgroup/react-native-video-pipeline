# Compose — Skia drawing (zero-copy on iOS)

The library itself **never imports Skia** — that's a hard invariant (see `CLAUDE.md`). When you reach for Skia in a worklet, you bring `@shopify/react-native-skia` yourself, plus the sibling helper `react-native-video-pipeline-skia` which exposes `drawWithSkia`.

The helper feature-detects the iOS GPU fast path:

- **iOS:** Skia draws into a Metal texture, then the native pump issues an `MTLBlitCommandEncoder copyFromTexture:toTexture:` into the encoder's `CVPixelBuffer` — zero CPU readback.
- **Android:** Skia renders into a CPU surface and the helper falls back to `target.writeBytes` — one memcpy. The AHardwareBuffer fast path is on the roadmap.

## Install (consumer side)

```sh
yarn add @shopify/react-native-skia react-native-video-pipeline-skia
```

## Basic usage

```ts
import { Video } from 'react-native-video-pipeline';
import { drawWithSkia } from 'react-native-video-pipeline-skia';
import { Skia } from '@shopify/react-native-skia';

await Video.compose(
  {
    output: { path: `${dir}/skia.mp4` },
    clips: [{ uri: sourceUri, startSec: 0, durationSec: 5 }],
  },
  {
    drawFrame: drawWithSkia((canvas, ctx) => {
      'worklet';
      const paint = Skia.Paint();
      paint.setColor(Skia.Color('red'));
      canvas.drawCircle(
        ctx.width / 2,
        ctx.height / 2,
        Math.min(ctx.width, ctx.height) / 4,
        paint,
      );
    }),
  },
);
```

## Sampling the source frame

On iOS, `ctx.source.unstable_bufferAddr` is a non-zero `bigint` — pass it to `Skia.Image.MakeImageFromNativeBuffer(unstable_bufferAddr)` for zero-copy sampling. On Android (today), use `Skia.Image.MakeImage(info, ctx.source.readBytes(), stride)` — the helper handles the platform check for you when you go through `drawWithSkia`.

```ts
drawFrame: drawWithSkia((canvas, ctx) => {
  'worklet';
  if (ctx.source !== undefined) {
    const img = ctx.sourceAsSkiaImage(); // helper provided by drawWithSkia
    canvas.drawImage(img, 0, 0);
    // overlay your Skia drawing on top
  }
}),
```

## Synthesize with Skia

Same helper, no clips:

```ts
await Video.synthesize({
  output: { path: `${dir}/skia-synth.mp4`, width: 720, height: 720, fps: 30 },
  duration: { mode: 'fixed', seconds: 3 },
  drawFrame: drawWithSkia((canvas, ctx) => {
    'worklet';
    canvas.clear(Skia.Color('black'));
    // draw whatever you want, keyed on ctx.frameIndex / ctx.timeSec
  }),
});
```

## Performance notes

- **Avoid retaining** the `FrameTarget` / `FrameSource` past the `drawFrame` return — they're invalidated by the native pump.
- **Reuse paints / fonts / images** declared outside the worklet via shared values — allocating per frame burns into the encoder's frame budget.
- **Match `output.fps` to your scene complexity.** Synthesize is offline, so the encoder runs as fast as your worklet does. A complex Skia scene at 60 fps may render slower than realtime; that's fine — output PTS is `frameIndex / fps`, never wall-clock.

## See also

- [`compose.md`](./compose.md) — `drawWithRGBA` path (no Skia)
- [`../rendering-ios.md`](../rendering-ios.md) — the three iOS render paths and how they share `CVPixelBuffer`
- [`../rendering-android.md`](../rendering-android.md) — Android pipeline and Y-flip discipline
