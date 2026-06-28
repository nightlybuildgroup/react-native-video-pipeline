# Flip horizontally or vertically

`Video.flip` mirrors a clip along one axis. mp4 / mov containers can express horizontal flip as a rotation flag — that path is a remux. Vertical flip and any container without a rotation flag fall into transcode.

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
  axis: 'vertical', // forces transcode in mp4
});
```

## When you also want to trim

`Video.trim` is a pure lossless cut and takes no transform. To cut **and** flip in one pass, use `Video.render` with a clip `transform` — the native router transcodes flip uniformly across platforms:

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
