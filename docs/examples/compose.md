# Compose — per-frame drawing on a clip

`Video.compose` runs your `drawFrame` worklet on top of source clips. The same `CVPixelBuffer` (iOS) / `AHardwareBuffer` (Android) the encoder will append is handed to the worklet — write into it and return.

> `drawFrame` must be a worklet. Install [`babel-plugin-video-pipeline`](../../packages/babel-plugin-video-pipeline/README.md) so a missing `'worklet';` directive fails the bundle instead of crashing on the first frame.

## Plain-pixel drawing with `drawWithRGBA`

The simplest path. `drawWithRGBA` hands you a `Uint8Array` of length `width * height * 4` to fill — no Skia required.

```ts
import { Video, Overlay, drawWithRGBA } from 'react-native-video-pipeline';

await Video.compose(
  {
    output: { path: `${dir}/composed.mp4` },
    clips: [
      { uri: sourceUri, startSec: 0, durationSec: 5 },
    ],
  },
  {
    drawFrame: drawWithRGBA((pixels, ctx) => {
      'worklet';
      // tint: copy source through, then bias the red channel by frameIndex
      ctx.source?.readBytes(); // optional — sample source pixels here
      for (let i = 0; i < pixels.length; i += 4) {
        pixels[i]     = (ctx.frameIndex * 4) & 0xff;
        pixels[i + 1] = 0;
        pixels[i + 2] = 0;
        pixels[i + 3] = 255;
      }
    }),
  },
);
```

`pixels` is RGBA premultiplied regardless of platform — the helper swizzles to BGRA on iOS internally.

## Reading the source frame

`ctx.source` is a `FrameSource` HybridObject. It's only valid inside the enclosing `drawFrame` call — don't retain it.

```ts
drawFrame: drawWithRGBA((pixels, ctx) => {
  'worklet';
  if (ctx.source !== undefined) {
    const src = new Uint8Array(ctx.source.readBytes()); // RGBA8888, top-down
    // ... composite src into pixels ...
  }
}),
```

On iOS, `ctx.source.unstable_bufferAddr` is a non-zero `bigint` you can pass to Skia for zero-copy sampling — see [`compose-skia.md`](./compose-skia.md).

## Mixing with native overlays

Native overlays composite **under** your `drawFrame` output. Useful for "Skia overlay on top of a native watermark".

```ts
await Video.compose(
  {
    output: { path: `${dir}/composed.mp4` },
    clips: [{ uri: sourceUri, startSec: 0, durationSec: 5 }],
    overlays: [
      Overlay.Image({ uri: logoUri, anchor: 'br', size: { w: 0.2 } }),
    ],
  },
  {
    drawFrame: myDrawer, // named identifier, declares 'worklet' itself
  },
);
```

`spec.overlays` may mix native overlays (`Overlay.Image` / `Overlay.Text`) freely; they composite under your `drawFrame` output. JS-side per-frame drawing only happens through `drawFrame`, never through `spec.overlays`.

## Errors

- `InvalidSpecError` — `drawFrame` missing
- Worklet-directive crash on first frame — install `babel-plugin-video-pipeline`

## See also

- [`compose-skia.md`](./compose-skia.md) — Skia path with the iOS GPU fast path
- [`synthesize.md`](./synthesize.md) — null-input compose (no source clips)
- [`../api.md#videocompose`](../api.md#videocompose) — full type reference
- [`../rendering-ios.md`](../rendering-ios.md), [`../rendering-android.md`](../rendering-android.md) — pipeline architecture
