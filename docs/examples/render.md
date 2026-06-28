# Render: trim + transform in one pass

`Video.render` is the full-spec engine. For single-clip edits it doubles as the place to **trim and transform at the same time** — something `Video.trim` deliberately doesn't do (it stays a pure lossless cut).

You describe *what* you want; the native router picks the cheapest path that works on each platform and **produces the correct output on both**. Source audio is preserved, and a trim window composes with the transform in the same pass. The path differs only in speed/quality:

| transform | iOS | Android |
| --- | --- | --- |
| `rotate` | remux (lossless, fast) | transcode (re-encode) |
| `flipH` / `flipV` | remux (lossless, fast) | transcode (re-encode) |
| `crop` | transcode (re-encode) | transcode (re-encode) |

(Android's container can't store a mirror, and bakes rotation into pixels in the same pass — so it re-encodes for any transform. iOS expresses rotation/flip losslessly in the container transform.)

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

On iOS this is a lossless **remux** (the flip lives in the container transform); on Android it **transcodes** (the container can't store a mirror). Either way the output is a correctly-mirrored 5-second clip with its audio intact.

## Trim + rotate

Trimming and rotating together — lossless **remux** on iOS, **transcode** on Android (both correct):

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
