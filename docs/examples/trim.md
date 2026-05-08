# Trim a clip

`Video.trim` cuts a sub-range out of a source clip. With no `transform`, or a rotation-only transform, the operation is a **remux** — bytes are copied straight through and no re-encode happens. Adding `crop`, `flipH`, or `flipV` falls into transcode.

## Plain trim (remux)

```ts
import { Video } from 'react-native-video-pipeline';

await Video.trim(sourceUri, {
  outPath: `${dir}/trimmed.mp4`,
  startSec: 2,
  durationSec: 5,
});
```

The output is bit-identical to the source for the trimmed range — codec, bitrate, color profile, audio track all preserved.

## Trim with rotation (still remux)

Rotation is metadata in mp4 / mov containers — flipping the rotation flag doesn't touch pixel data.

```ts
await Video.trim(sourceUri, {
  outPath: `${dir}/trimmed-rot.mp4`,
  startSec: 0,
  durationSec: 3,
  transform: { rotate: 90 },
});
```

## Trim with crop (transcode)

```ts
await Video.trim(sourceUri, {
  outPath: `${dir}/trimmed-cropped.mp4`,
  startSec: 0,
  durationSec: 3,
  transform: {
    crop: { x: 100, y: 100, w: 720, h: 720 },
  },
});
```

`crop` coordinates are in **source pixels**, not output pixels. The output dimensions are inferred from the crop rectangle.

## Errors

- `InvalidSpecError` — `startSec` is negative or `durationSec` is non-positive
- `IOError` — source not readable or `outPath` not writable
- `SourceCorruptedError` — source could not be parsed

## See also

- [`flip.md`](./flip.md) — pure flip without trimming
- [`../api.md#videotrim`](../api.md#videotrim) — full type reference
