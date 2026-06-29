# Stamp a watermark or metadata

`Video.stamp` adds a watermark, writes metadata, or both. A metadata-only stamp is a **remux** (writes container atoms, no pixel work). Adding a `watermark` falls into transcode.

## Metadata only (remux)

```ts
import { Video } from 'react-native-video-pipeline';

await Video.stamp(sourceUri, {
  outPath: `${dir}/stamped.mp4`,
  metadata: {
    software: 'MyApp 1.4',
    creationDate: new Date(),
    location: { latitude: 52.5200, longitude: 13.4050 }, // WGS-84
    description: 'B-roll, take 3',
    custom: { sceneId: 'S07', cameraOp: 'KB' },
  },
});
```

`location` lands in the standard `udta/©xyz` atom; `creationDate` uses the container's native timestamp field; `custom` keys round-trip through `Video.info(uri).custom`. Caller owns the keys — the library doesn't add a namespace prefix.

## Image watermark (transcode)

```ts
import { Video, Overlay } from 'react-native-video-pipeline';

await Video.stamp(sourceUri, {
  outPath: `${dir}/wm.mp4`,
  watermark: Overlay.Image({
    uri: logoUri,
    anchor: 'br',                  // bottom-right
    // 20% of output width, height scales proportionally.
    size: { width: { unit: 'ratio', value: 0.2 } },
    opacity: 0.85,
    timeRange: { startSec: 0, endSec: 5 }, // optional; omit for full duration
  }),
});
```

`anchor` accepts presets (`'tl' | 'tr' | 'bl' | 'br' | 'center'`) or a normalized `{ x: 0..1, y: 0..1 }` point.

## Text watermark

```ts
await Video.stamp(sourceUri, {
  outPath: `${dir}/wm-text.mp4`,
  watermark: Overlay.Text({
    text: 'CONFIDENTIAL',
    style: {
      fontSize: 48,
      color: '#ff3b30',
      weight: 'bold',
      align: 'center',
      shadow: { color: '#000000aa', blur: 4, dx: 0, dy: 2 },
    },
    anchor: 'center',
  }),
});
```

Text is rendered natively (`CoreText` on iOS, Media3 `TextOverlay` on Android). Cross-platform pixel-identical text is **not** a goal — if you need that, rasterize a PNG yourself and use `Overlay.Image`.

## Watermark + metadata together

```ts
await Video.stamp(sourceUri, {
  outPath: `${dir}/wm-and-meta.mp4`,
  watermark: Overlay.Image({
    uri: logoUri,
    anchor: 'br',
    size: { width: { unit: 'ratio', value: 0.15 } },
  }),
  metadata: { software: 'MyApp 1.4' },
});
```

This still routes to transcode (because of the watermark) and writes the metadata in the same pass.

## Errors

- `InvalidSpecError` — neither `watermark` nor `metadata` provided, or `watermark` is a worklet (use `Video.compose` instead)
- `IOError` — watermark `uri` not readable, or `outPath` not writable

## See also

- [`compose.md`](./compose.md) — for per-frame drawing instead of a static overlay
- [`probe.md`](./probe.md) — read back the metadata you wrote
- [`../api.md#videostamp`](../api.md#videostamp) — full type reference
