# Render: trim + transform in one pass

`Video.render` is the full-spec engine. For single-clip edits it doubles as the place to **trim and transform at the same time** — something `Video.trim` deliberately doesn't do (it stays a pure lossless cut).

The native router picks the cheapest path automatically, and it does so **identically on iOS and Android**:

- rotation-only transform → **remux** (lossless, no re-encode)
- `flipH` / `flipV` / `crop` → **transcode** (re-encode)

So you describe *what* you want; the library decides remux vs transcode. No per-platform branching in your code.

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

Because `flipH` touches pixels, this routes to **transcode** on both platforms. (A standalone flip with no trim can stay on the cheaper `Video.flip` remux path on iOS — see [`flip.md`](./flip.md).)

## Trim + rotate (stays remux)

Rotation is a container flag, so trimming and rotating together is still a lossless **remux** on both iOS and Android — no quality loss, near-instant:

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

## Progress

Transcode paths (`flipH` / `flipV` / `crop`) report per-frame progress; pass `onProgress` in the options argument:

```ts
await Video.render(
  { clips: [{ uri: sourceUri, startSec: 2, durationSec: 5, transform: { flipH: true } }],
    output: { path: `${dir}/out.mp4` } },
  { onProgress: ({ framesCompleted, nbFrames }) => console.log(`${framesCompleted}/${nbFrames}`) },
);
```

Remux paths (rotation-only) complete in milliseconds and don't report per-frame progress — just await the promise.

## See also

- [`trim.md`](./trim.md) — the lossless-cut primitive (no transform)
- [`flip.md`](./flip.md) — standalone flip
- [`../api.md#videorender`](../api.md#videorender) — full `RenderSpec` type reference
- [`../api.md#routing-rules`](../api.md#routing-rules) — remux vs transcode decisions
