# Trim a clip

`Video.trim` cuts a sub-range out of a source clip. It is the **lossless-cut primitive**: the operation is always a **remux** — bytes are copied straight through, no re-encode — on both iOS and Android. `trim` takes no transform; to trim *and* transform in one pass, see [`render.md`](./render.md).

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

End-past-EOF requests (`startSec + durationSec` longer than the source) are silently clamped to the source's real duration. Only a `startSec` past the end rejects with `InvalidSpecError`.

## Trim *and* transform → use `Video.render`

`trim` deliberately stays a pure cut. The moment you also want to rotate, flip, or crop, reach for `Video.render` — it produces the correct output on both platforms, taking the fast lossless remux path where it can (iOS rotation/flip) and re-encoding otherwise (crop everywhere; rotation/flip on Android), with the trim window applied in the same pass. See [`render.md`](./render.md).

## Errors

- `InvalidSpecError` — `startSec` is negative or `durationSec` is non-positive
- `IOError` — source not readable or `outPath` not writable
- `SourceCorruptedError` — source could not be parsed

## See also

- [`render.md`](./render.md) — trim + flip / rotate / crop in one pass
- [`flip.md`](./flip.md) — pure flip without trimming
- [`../api.md#videotrim`](../api.md#videotrim) — full type reference
