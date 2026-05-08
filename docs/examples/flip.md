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

Use `Video.trim` with a `transform.flipH` or `transform.flipV` — same routing rules apply.

```ts
await Video.trim(sourceUri, {
  outPath: `${dir}/trimmed-flipped.mp4`,
  startSec: 1,
  durationSec: 4,
  transform: { flipH: true },
});
```

## See also

- [`trim.md`](./trim.md) — combine trim + flip
- [`../api.md#videoflip`](../api.md#videoflip) — full type reference
