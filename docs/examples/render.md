# Render: trim + transform in one pass

`Video.render` is the full-spec engine. For single-clip edits it doubles as the place to **trim and transform at the same time** — something `Video.trim` deliberately doesn't do (it stays a pure lossless cut).

You describe *what* you want; each platform produces the **correct output** and **preserves the source audio**, and a trim window composes with the transform in the same pass. The engine differs:

- **iOS** — rotation/flip take the lossless **remux** path (the transform lives in the container's `preferredTransform`); `crop` re-encodes.
- **Android** — runs on **Media3 Transformer**, which transmuxes (copies compressed samples, no re-encode) when the edit needs no pixel work and re-encodes otherwise.

So a rotate/flip on iOS is near-instant and lossless; the same edit on Android is correct and may transmux, but isn't guaranteed lossless. Cropping re-encodes everywhere.

## Trim + horizontal flip

Cut seconds 2–7 out of the source and mirror it horizontally, in a single decode/encode pass:

```ts
import { Video } from 'react-native-video-pipeline';

await Video.render({
  clips: [
    {
      uri: sourceUri,
      startSec: 2,
      durationSec: 5,
      transform: { flipH: true },
    },
  ],
  // Omit width/height/fps to inherit them from the source clip.
  output: { path: `${dir}/trimmed-flipped.mp4` },
});
```

On iOS this is a lossless **remux** (the flip lives in the container transform); on Android it runs through **Media3 Transformer**. Either way the output is a correctly-mirrored 5-second clip with its audio intact.

## Trim + rotate

Trimming and rotating together — lossless **remux** on iOS, **Media3 Transformer** on Android (both correct, audio preserved):

```ts
await Video.render({
  clips: [{ uri: sourceUri, startSec: 0, durationSec: 3, transform: { rotate: 90 } }],
  output: { path: `${dir}/trimmed-rotated.mp4` },
});
```

## Trim + crop

`crop` coordinates are in **source pixels** (coded space — see `codedWidth` / `codedHeight` from [`Video.info`](../api.md#videoinfo)). Cropping re-cuts the pixel grid, so this **transcodes**:

```ts
await Video.render({
  clips: [
    {
      uri: sourceUri,
      startSec: 0,
      durationSec: 3,
      transform: { crop: { x: 100, y: 100, w: 720, h: 720 } },
    },
  ],
  output: { path: `${dir}/trimmed-cropped.mp4`, width: 720, height: 720 },
});
```

## Multi-clip note

Per-clip transforms apply to a **single-clip** render. A multi-clip spec is passthrough-concat only — combining concat with a transform (or overlay, or output-side change) rejects with `InvalidSpecError` until multi-clip transcode lands. To concat *and* transform, render each clip, then concat the results.

## Progress

The transcode path reports per-frame progress; pass `onProgress` in the options argument:

```ts
await Video.render(
  { clips: [{ uri: sourceUri, startSec: 2, durationSec: 5, transform: { crop: { x: 0, y: 0, w: 640, h: 640 } } }],
    output: { path: `${dir}/out.mp4`, width: 640, height: 640 } },
  { onProgress: ({ framesCompleted, nbFrames }) => console.log(`${framesCompleted}/${nbFrames}`) },
);
```

A remux (iOS rotation/flip) completes in milliseconds and doesn't report per-frame progress — just await the promise.

## See also

- [`trim.md`](./trim.md) — the lossless-cut primitive (no transform)
- [`flip.md`](./flip.md) — standalone flip
- [`../api.md#videorender`](../api.md#videorender) — full `RenderSpec` type reference
- [`../api.md#routing-rules`](../api.md#routing-rules) — remux vs transcode decisions
