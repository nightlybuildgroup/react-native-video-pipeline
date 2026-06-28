# Flip horizontally or vertically

`Video.flip` mirrors a clip along one axis, on **both iOS and Android**.

**Platform behavior.** A mirror is an affine transform (scale by −1), not a plain rotation. iOS stores it losslessly in the container's `preferredTransform`, so `Video.flip` is a passthrough **remux** (no re-encode, no progress events). Android's `MediaMuxer` can only store an orientation hint (0/90/180/270), never a mirror, so on Android `Video.flip` re-encodes the pixels via **Media3 Transformer** — audio and the source codec (H.264 → H.264, HEVC → HEVC) are preserved, and `onProgress` fires.

```ts
import { Video } from 'react-native-video-pipeline';

await Video.flip(sourceUri, {
  outPath: `${dir}/flipped.mp4`,
  axis: 'horizontal',
});
```

```ts
await Video.flip(sourceUri, {
  outPath: `${dir}/flipped-v.mp4`,
  axis: 'vertical',
});
```

## When you also want to trim

`Video.trim` is a pure lossless cut and takes no transform. To cut **and** flip in one pass, use `Video.render` with a clip `transform` — a lossless remux on iOS, a re-encode on Android (both keep the audio):

```ts
await Video.render({
  clips: [{ uri: sourceUri, startSec: 1, durationSec: 4, transform: { flipH: true } }],
  output: { path: `${dir}/trimmed-flipped.mp4` },
});
```

## See also

- [`render.md`](./render.md) — combine trim + flip / rotate / crop in one pass
- [`trim.md`](./trim.md) — the lossless-cut primitive
- [`../api.md#videoflip`](../api.md#videoflip) — full type reference
