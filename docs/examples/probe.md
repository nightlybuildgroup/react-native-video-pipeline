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
- `InvalidSpecError` — `thumbnail.atSec` is negative

## See also

- [`stamp.md`](./stamp.md) — write the metadata you read back here
- [`../api.md#videoinfo`](../api.md#videoinfo) — full type reference
