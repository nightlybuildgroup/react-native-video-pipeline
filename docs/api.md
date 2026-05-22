# API Reference

The complete public surface of `react-native-video-pipeline`. The Nitro spec at `packages/react-native-video-pipeline/src/nitro/VideoPipeline.nitro.ts` is the single source of truth — this page is a curated, prose-friendly view of the same types.

For runnable scenarios see [`docs/examples/`](./examples/). For architectural deep-dives see [`docs/rendering-ios.md`](./rendering-ios.md) and [`docs/rendering-android.md`](./rendering-android.md).

## Contents

- [`Video`](#video) — top-level operations
  - [`Video.info`](#videoinfo)
  - [`Video.thumbnail`](#videothumbnail)
  - [`Video.capabilities`](#videocapabilities)
  - [`Video.trim`](#videotrim)
  - [`Video.flip`](#videoflip)
  - [`Video.stamp`](#videostamp)
  - [`Video.render`](#videorender)
  - [`Video.compose`](#videocompose)
  - [`Video.synthesize`](#videosynthesize)
- [`Overlay`](#overlay) — overlay builders
- [`drawWithRGBA`](#drawwithrgba) — plain-pixel worklet helper
- [`VideoRenderController`](#videorendercontroller) — graceful end-of-stream
- [Errors](#errors) — `VideoPipelineError` and subclasses
- [Types](#types) — specs, options, frame contexts
- [Routing rules](#routing-rules) — when each execution path is used

---

## `Video`

Imported as a single namespace:

```ts
import { Video } from 'react-native-video-pipeline';
```

### `Video.info`

```ts
Video.info(uri: string): Promise<VideoInfo>
```

Probe a video file. Returns container, codec, dimensions, frame rate, duration, audio presence, HDR, rotation, plus any `creationDate`, `gnss`, and `custom` metadata previously written by `Video.stamp` (or by another tool that wrote to the standard `udta` atoms).

`width` / `height` are the **displayed** dimensions — what a viewer sees, after the container's rotation metadata is applied. The pre-rotation pixel grid is exposed as `codedWidth` / `codedHeight` (matches `AVAssetTrack.naturalSize` on iOS and `MediaFormat.KEY_WIDTH/HEIGHT` on Android, and follows the WebCodecs `codedWidth` vs `displayWidth` naming convention). `ClipTransform.crop` is expressed in source-pixel coordinates (coded-space), so consumers building crops should reach for `codedWidth` / `codedHeight`; everything else (overlay sizing, aspect ratios, UI layout) wants `width` / `height`.

### `Video.thumbnail`

```ts
Video.thumbnail(uri: string, options: ThumbnailOptions): Promise<string>
```

Extract one JPEG frame at `options.atSec` and write it to `options.outPath`. Resolves to the absolute output path. `options.resizeTo` is optional; provide one of `w` or `h` to scale proportionally.

### `Video.capabilities`

```ts
Video.capabilities(): Promise<EncoderCaps>
```

Cached encoder capability snapshot — supported codecs, max dimensions and fps, max bitrate, HDR support. Use this to decide whether to ask for `hevc` or fall back to `h264` before calling `Video.render`.

### `Video.trim`

```ts
Video.trim(uri: string, options: TrimOptions): Promise<void>
```

Trim a clip. Always remuxes (passthrough — no re-encode) when `options.transform` is `undefined` or rotation-only; transcodes when `transform.crop`, `flipH`, or `flipV` is present. See [Routing rules](#routing-rules).

End-past-EOF requests (`startSec + durationSec > sourceDuration`) are silently clamped to the source's actual duration — matches `AVAssetExportSession` and ffmpeg leniency. This absorbs muxer-vs-encoder rounding drift (e.g. recorders that report a target duration ~10ms shorter than the bytes they actually wrote). Only `startSec` past EOF rejects with `InvalidSpec`.

### `Video.flip`

```ts
Video.flip(uri: string, options: FlipOptions): Promise<void>
```

Flip horizontally or vertically. Uses a rotation-flag remux when the container supports it (mp4 ↔ mov); transcodes otherwise.

### `Video.stamp`

```ts
Video.stamp(uri: string, options: StampOptions): Promise<void>
```

Add a watermark and/or write metadata. Metadata-only stamps remux (fast); a `watermark` of kind `'image'` or `'text'` falls into transcode. Worklet watermarks are not allowed here — pass them through `Video.compose`. Either `watermark` or `metadata` must be provided.

### `Video.render`

```ts
Video.render(spec: VideoSpec, options?: RenderOptions): Promise<void>
```

The single source of truth for trim / transcode / compose. The native side picks the cheapest path based on `spec`:

- All-passthrough spec (no overlays, no transforms beyond rotation flags) → **remux**
- Native-overlay or transform spec → **transcode**
- Worklet overlay or null-input synthesis → **compose**

Worklet overlays added via `Overlay.Worklet(...)` are stripped before crossing Nitro and dispatched through the worklet runtime. Prefer the dedicated [`Video.compose`](#videocompose) / [`Video.synthesize`](#videosynthesize) sugar when you have a `drawFrame` — it skips the overlay-list round-trip and gives clearer types.

### `Video.compose`

```ts
Video.compose(spec: VideoSpec, options: ComposeOptions): Promise<void>
```

Per-frame worklet drawing on top of source clips. The `options.drawFrame` callback runs on the Reanimated UI runtime once per output frame and writes pixels into a pre-allocated `FrameTarget`. The same `CVPixelBuffer` (iOS) / `AHardwareBuffer` (Android) is then handed to the encoder — no intermediate copy.

`drawFrame` must be a worklet. The recommended way to enforce this is the build-time [`babel-plugin-video-pipeline`](#worklet-directive-enforcement) check; without it, the first frame crashes at runtime with a directive-missing error.

`spec.overlays` must not contain a worklet overlay when calling `Video.compose` directly — that would double-dispatch. Mix native overlays freely; they composite under your `drawFrame` output.

### `Video.synthesize`

```ts
Video.synthesize(options: SynthesizeOptions): Promise<void>
```

Null-input compose: no source clips, the entire frame stream comes from `options.drawFrame`. `output.width`, `output.height`, `output.fps`, and `duration` are all required. Use `duration: { mode: 'open' }` plus an `AbortSignal` or `VideoRenderController` for indeterminate-length renders.

`ctx.source` is always `undefined` on this path — there is no source frame to sample.

---

## `Overlay`

```ts
import { Overlay } from 'react-native-video-pipeline';
```

Builder functions for the three overlay variants. They normalize `anchor` presets (`'tl' | 'tr' | 'bl' | 'br' | 'center'`) into normalized `{ x, y }` points before crossing the Nitro boundary, which is why they exist as functions rather than plain object literals.

The normalized anchor is a **slot position within the free space** (output frame minus overlay): `(0, 0)` aligns the overlay's top-left with the frame's top-left; `(1, 1)` aligns its bottom-right with the frame's; `(0.5, 0.5)` centers it. Anchors always align corresponding edges — they do not address an arbitrary point on the overlay. Pixel-from-edge layouts can be expressed as `anchor.x = inset / (outputW - overlayW)`.

```ts
Overlay.Image({ uri, anchor, size, opacity?, timeRange? }): ImageOverlayValue
Overlay.Text({ text, style, anchor, timeRange? }): TextOverlayValue
Overlay.Worklet({ draw, timeRange? }): WorkletOverlayValue
```

`Overlay.Image` and `Overlay.Text` are rendered natively (`CIFilter` + `CATextLayer` on iOS, Media3 `BitmapOverlay` + `TextOverlay` on Android). Advanced typography is intentionally out of scope; if you need pixel-identical cross-platform text, rasterize a PNG and use `Overlay.Image`.

`Overlay.Worklet` enters the compose path. Prefer `Video.compose({ drawFrame })` over a single worklet overlay — it has clearer semantics and skips one indirection.

---

## `drawWithRGBA`

```ts
import { drawWithRGBA, type RGBADrawer } from 'react-native-video-pipeline';

drawWithRGBA(draw: RGBADrawer): FrameDrawer
```

Wraps a plain `(pixels, ctx) => void` callback into a `FrameDrawer`. The helper allocates a `Uint8Array` of length `ctx.width * ctx.height * 4`, calls your drawer, and copies the bytes into the native target. On iOS it swizzles RGBA → BGRA to match `kCVPixelFormatType_32BGRA`; on Android the bytes match the native layout directly.

Alpha is **premultiplied** RGBA. On `Video.synthesize` (H.264 output has no alpha channel) you can write `a = 255` and ignore alpha. On `Video.compose` over a clip, alpha is the blend key.

For Skia-based drawing, the sibling package `react-native-video-pipeline-skia` provides `drawWithSkia`, which can reach zero-copy on iOS via `MTLBlitCommandEncoder`.

---

## `VideoRenderController`

```ts
import { VideoRenderController } from 'react-native-video-pipeline';

const controller = new VideoRenderController();
const promise = Video.synthesize({ ..., controller });
// later:
controller.finish(); // graceful end-of-stream — promise resolves
controller.abort();  // discard output — promise rejects with CancelledError
```

Distinct from `AbortSignal`:

- `abort()` cancels and **discards** the output. The render promise rejects with `CancelledError`.
- `finish()` stops after the current frame and **finalizes** the output. The render promise resolves normally. No-op on fixed-duration renders — use `AbortSignal` to stop a fixed render early.

State transitions:

```
running → finishing → done    (graceful: finish() then native flush)
running → done                (fixed-duration natural end)
running → aborted             (hard cancel)
finishing → aborted           (abort wins over in-flight finish)
```

Both methods are idempotent. A controller maps 1:1 to a render — pass a fresh instance per `Video.*` call. Reuse throws.

`AbortSignal` and `VideoRenderController` can be combined; either one cancelling causes the render to stop.

---

## Errors

All errors thrown by the library extend `VideoPipelineError`, which extends `Error` with two extra fields:

- `code: VideoPipelineErrorCode` — discriminant
- `details?: Record<string, unknown>` — diagnostic context

```ts
import {
  VideoPipelineError,
  UnsupportedCodecError,
  DeviceCapabilityExceededError,
  SourceCorruptedError,
  CancelledError,
  IOError,
  EncoderFailureError,
  InvalidSpecError,
  errorForCode,
} from 'react-native-video-pipeline';
```

| Code                       | Class                           | When                                                                |
| -------------------------- | ------------------------------- | ------------------------------------------------------------------- |
| `UnsupportedCodec`         | `UnsupportedCodecError`         | Source codec unsupported by the platform decoder                    |
| `DeviceCapabilityExceeded` | `DeviceCapabilityExceededError` | Output exceeds `EncoderCaps` (max dims, fps, bitrate, HDR)          |
| `SourceCorrupted`          | `SourceCorruptedError`          | File could not be parsed                                            |
| `Cancelled`                | `CancelledError`                | `AbortSignal.abort()` or `VideoRenderController.abort()`            |
| `IOError`                  | `IOError`                       | Read / write failed (path missing, permissions, disk full)          |
| `EncoderFailure`           | `EncoderFailureError`           | Native encoder error not classifiable as one of the above           |
| `InvalidSpec`              | `InvalidSpecError`              | The `VideoSpec` / options object failed JS-side or native-side validation |

`errorForCode(code, options?)` constructs the right subclass for a code — useful when relaying an error across boundaries.

`assertNever(x: never): never` is exported for exhaustiveness checks in consumer code that switches on a discriminated union from this library.

---

## Types

The full type list is exported from the package root and re-exported from the Nitro spec. The most load-bearing ones:

### `VideoSpec`

```ts
interface VideoSpec {
  output: OutputSpec;
  clips?: Clip[];           // omit/empty → synthesize path; requires duration + worklet
  overlays?: OverlayValue[]; // image / text / worklet
  audio?: AudioSpec;
  metadata?: MetadataSpec;
  duration?: DurationSpec;  // required when clips is omitted
}
```

### `OutputSpec`

```ts
interface OutputSpec {
  path: string;
  width?: number;     // required when clips is empty
  height?: number;    // required when clips is empty
  fps?: number;       // required when clips is empty
  bitrate?: number;   // bits per second
  codec?: VideoCodec; // 'h264' | 'hevc'; default 'h264'
  container?: VideoContainer; // 'mp4' | 'mov'
}
```

### `Clip` and `ClipTransform`

```ts
interface Clip {
  uri: string;
  sourceStart: number;     // seconds into source
  sourceDuration: number;
  outputStart: number;     // seconds on output timeline
  transform?: ClipTransform;
}

interface ClipTransform {
  rotate?: 0 | 90 | 180 | 270;
  flipH?: boolean;
  flipV?: boolean;
  crop?: { x: number; y: number; w: number; h: number }; // source-pixel coords
}
```

A `transform` of rotation-only stays in remux. Any of `flipH`, `flipV`, or `crop` forces transcode.

### `DurationSpec`

```ts
type DurationSpec =
  | { mode: 'fixed'; seconds: number }
  | { mode: 'open'; maxSeconds?: number };
```

`'open'` requires either an `AbortSignal` or a `VideoRenderController` so the render can be stopped.

### `RenderOptions`

```ts
interface RenderOptions {
  signal?: AbortSignal;
  controller?: VideoRenderController;
  onProgress?: (p: Progress) => void;
  priority?: 'interactive' | 'background'; // default 'interactive'
}
```

### `Progress`

```ts
interface Progress {
  framesCompleted: number;
  nbFrames?: number;            // undefined for open-ended until finish() is called
  elapsedMs: number;
  estimatedRemainingMs?: number;
}
```

### `MetadataSpec`

```ts
interface MetadataSpec {
  gnss?: { latitude: number; longitude: number }; // WGS-84
  software?: string;
  creationDate?: Date;
  description?: string;
  custom?: Record<string, string>;
}
```

`gnss` is named for the *datum* (WGS-84) rather than the sensor, so it accepts any GNSS source (GPS, GLONASS, Galileo, BeiDou, …) or a corrected non-satellite resolver. Container muxers serialize it to the standard `udta/©xyz` atom.

`custom` keys round-trip through the library — caller owns the keys; no namespace prefix is added.

### `AudioSpec`

```ts
interface AudioSpec {
  mode: 'passthrough' | 'mute' | 'replace';
  replaceUri?: string; // required when mode === 'replace'
}
```

### `FrameDrawerContext`

The argument to `drawFrame` on the compose / synthesize path:

```ts
interface FrameDrawerContext {
  target: FrameTarget;            // write here
  source?: FrameSource;           // current source frame (compose-on-clip only)
  frameIndex: number;             // 0-based output frame counter
  timeSec: number;                // frameIndex / fps — output PTS
  elapsedMs: number;              // wall-clock since render start
  width: number;
  height: number;
  finish(): void;                 // graceful stop on open-ended renders
}
```

The `target` and `source` HybridObjects are **valid only during the enclosing `drawFrame` call**. The native pump invalidates them on return. Don't retain the pointer; don't pass them to async work.

### `FrameTarget` / `FrameSource`

Pixel-buffer handles backed by `CVPixelBuffer` (iOS) or `AHardwareBuffer` (Android). Both expose `bufferAddr: bigint`, `width`, `height`, and `format: 'bgra8888' | 'rgba8888'`.

- `target.writeBytes(bytes: ArrayBuffer)` — stable path, memcpy `width * height * 4` bytes
- `target.blitFromNativeTexture(mtlTexturePtr: bigint)` — iOS GPU fast path, zero-copy from a Metal texture
- `source.readBytes(): ArrayBuffer` — fresh RGBA8888 copy; raster fallback when `bufferAddr` is not directly mappable

### `EncoderCaps`

```ts
interface EncoderCaps {
  codecs: VideoCodec[];
  maxWidth: number;
  maxHeight: number;
  maxFps: number;
  maxBitrate: number;
  hdr: boolean;
}
```

---

## Routing rules

Each top-level operation maps to one of three internal execution paths. The decision is made on the native side from the `VideoSpec` shape:

| Path        | When                                                                                | Speed   |
| ----------- | ----------------------------------------------------------------------------------- | ------- |
| **remux**   | Passthrough — no overlays, no per-pixel transforms, output codec/container match    | Fastest |
| **transcode** | Native-only overlays (`image`, `text`), transforms with `crop`/`flip`, codec change | Medium  |
| **compose** | Worklet overlay or `drawFrame` callback present, OR no source clips (synthesize)    | Slowest |

The `Video.trim` / `Video.flip` / `Video.stamp` convenience wrappers exist so the routing decision lives in C++, not split across JS and native. `Video.render` is the explicit form.

---

## Worklet directive enforcement

`Video.compose` and `Video.synthesize` (and `Overlay.Worklet`) accept callbacks that run on the Reanimated UI runtime. Reanimated requires every such function to begin with `'worklet';` so it can be lifted to the UI thread.

`babel-plugin-video-pipeline` enforces this **at build time**:

- Inline function literals passed as `drawFrame` / `draw` must start with `'worklet';`. Missing directive → bundle fails.
- Named identifiers (`drawFrame: myDrawer`) are passed through — declare the directive on the function itself.

The library never runs the directive check at runtime; the guarantee is entirely build-time.

---

## See also

- [`docs/examples/`](./examples/) — runnable scenarios per operation
- [`docs/architecture.md`](./architecture.md) — repo layout, tech stack, locked-in design decisions
- [`docs/rendering-ios.md`](./rendering-ios.md), [`docs/rendering-android.md`](./rendering-android.md) — render-pipeline architecture
- `packages/react-native-video-pipeline/src/nitro/VideoPipeline.nitro.ts` — Nitro spec (single source of truth)
