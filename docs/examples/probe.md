# Probe a clip

Three read-only operations: `Video.info`, `Video.thumbnail`, `Video.capabilities`. None of them write a video file, none of them go through the routing rules.

## Read codec, dimensions, duration

```ts
import { Video } from 'react-native-video-pipeline';

const info = await Video.info(sourceUri);
// {
//   uri,
//   durationSec,
//   width, height,
//   fps,
//   bitRate,
//   codec,        // 'h264' | 'hevc' | ...
//   container,    // 'mp4' | 'mov' | ...
//   hasAudio,
//   isHDR,
//   rotation,     // 0 | 90 | 180 | 270
//   creationDate, // optional
//   location,     // optional WGS-84 coordinate
//   custom,       // optional Record<string, string>
// }
```

`creationDate`, `location`, and `custom` round-trip with `Video.stamp` — anything you wrote on the way out reads back here.

## Extract a thumbnail

```ts
const thumbPath = await Video.thumbnail(sourceUri, {
  atSec: 1.5,
  outPath: `${dir}/thumb.jpg`,
  resizeTo: { w: 320 }, // optional; height scales proportionally
});
// thumbPath === `${dir}/thumb.jpg`
```

Output is JPEG. Provide one of `resizeTo.w` or `resizeTo.h` to scale; omit `resizeTo` for native source resolution.

## Extract a filmstrip (batch)

For a scrubber strip or filmstrip — many evenly-spaced frames — use `Video.thumbnails` instead of looping `Video.thumbnail`. It opens the asset, walks the decoder forward **once**, and tears it down once, rather than paying a fresh asset-open + cold-seek per frame:

```ts
const { durationSec } = await Video.info(sourceUri);
const COUNT = 24;
const atSecs = Array.from({ length: COUNT }, (_, i) => (i / COUNT) * durationSec);
const outPaths = atSecs.map((_, i) => `${dir}/strip-${i}.jpg`);

const frames = await Video.thumbnails(sourceUri, {
  atSecs,
  outPaths,
  resizeTo: { w: 100 },
  toleranceSec: 0.5, // snap to nearest keyframe — cheap, fine for a strip
});
// frames[i] === outPaths[i] for each written frame; '' for any that failed
```

`atSecs` and `outPaths` are parallel arrays; the result is in `atSecs` order. A non-zero `toleranceSec` is the big speedup for strips (exact-frame decoding is the dominant cost on long clips). One frame failing leaves an empty string in its slot rather than rejecting the whole batch.

## Encoder capabilities

Use this to decide whether to ask for `hevc` or fall back to `h264`, or to pre-validate dimensions / fps before kicking off a long render.

```ts
const caps = await Video.capabilities();
// { codecs: ['h264', 'hevc'], maxWidth, maxHeight, maxFps, maxBitrate, hdr: boolean }

const codec = caps.codecs.includes('hevc') ? 'hevc' : 'h264';
const fps = Math.min(60, caps.maxFps);
```

The result is cached — calling `capabilities()` repeatedly is cheap.

## Errors

- `IOError` — `uri` not readable
- `SourceCorruptedError` — file could not be parsed
- `InvalidSpecError` — `thumbnail.atSec` is negative; or, for `thumbnails`, an empty `atSecs`, a length-mismatched `outPaths`, a negative `atSecs` entry, or a negative `toleranceSec`

## See also

- [`stamp.md`](./stamp.md) — write the metadata you read back here
- [`../api.md#videoinfo`](../api.md#videoinfo) — full type reference
