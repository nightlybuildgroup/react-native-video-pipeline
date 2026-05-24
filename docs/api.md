# API Reference

The complete public surface of `react-native-video-pipeline`. The Nitro spec at `packages/react-native-video-pipeline/src/nitro/VideoPipeline.nitro.ts` is the single source of truth — this page is a curated, prose-friendly view of the same types.

For runnable scenarios see [`docs/examples/`](./examples/). For architectural deep-dives see [`docs/rendering-ios.md`](./rendering-ios.md) and [`docs/rendering-android.md`](./rendering-android.md).

## Contents

- [Choosing a method](#choosing-a-method) — decision tree, when to use each entry point
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

## Choosing a method

Start here. The decision tree is shallow:

**1. Probing or reading metadata?** → `Video.info`, `Video.thumbnail`, `Video.capabilities`.

**2. Editing video?** Ask: *am I writing pixels from JavaScript?*

- **No** — the operation can be expressed as "the native side does X to this clip":
  - Single-clip trim, optionally with a transform → `Video.trim`.
  - Single-clip horizontal/vertical flip → `Video.flip`.
  - Add a watermark image/text and/or write metadata onto one clip → `Video.stamp`.
  - **Anything more complex** — multiple clips concatenated, multiple overlays, custom output codec/bitrate/dimensions, mixed transforms, audio replacement — → `Video.render` with a full `RenderSpec`.
- **Yes**, I want a worklet drawing on every frame:
  - Drawing *on top of* one or more source clips → `Video.compose`.
  - Generating frames from scratch with no source → `Video.synthesize`.

### Sugar vs `Video.render`

`Video.trim` / `Video.flip` / `Video.stamp` are fixed-signature sugar for the common single-clip cases. They exist because `Video.render({ clips: [{ uri, startSec, durationSec }], output: { ... } })` is verbose when all you want is one trim.

Use `Video.render` directly the moment your spec needs *anything* the sugar doesn't carry:

```ts
// Concat three clips, two overlays, custom output codec — only `render` does this.
await Video.render({
  clips: [
    { uri: 'intro.mp4', startSec: 0, durationSec: 2 },
    { uri: 'main.mp4', startSec: 5, durationSec: 30, transform: { crop: { x: 0, y: 0, w: 1920, h: 1080 } } },
    { uri: 'outro.mp4', startSec: 0, durationSec: 3 },
  ],
  overlays: [
    Overlay.Image({ uri: 'logo.png', anchor: 'tl', size: { w: 0.15 } }),
    Overlay.Text({ text: '@username', anchor: 'br', style: { fontSize: 24, color: '#fff' } }),
  ],
  audio: { mode: 'replace', replaceUri: 'soundtrack.m4a' },
  output: { path: '/tmp/out.mp4', width: 1920, height: 1080, fps: 30, codec: 'h264', bitrate: 8_000_000 },
});
```

Chaining `trim` → `stamp` → `render` through temp files would re-encode at every step (slow + lossy). One `Video.render` call decodes and encodes exactly once.

### `render` vs `compose`/`synthesize`

`Video.render` covers **remux and transcode** — the native side decodes/encodes (or passthrough-copies) frames without ever calling back into JavaScript. Overlays on this path are native (`CIFilter` + `CATextLayer` on iOS, Media3 `BitmapOverlay` + `TextOverlay` on Android).

`Video.compose` and `Video.synthesize` are the **only** entry points where your JS worklet draws into each frame. The native pump invokes `drawFrame` per frame with a live `FrameTarget`. That has different cost (per-frame JS overhead), different requirements (worklet directive, see [`babel-plugin-video-pipeline`](#worklet-directive-enforcement)), and different capabilities (arbitrary drawing via plain RGBA, Skia, or Metal texture blit) than the native overlay path.

If you need pixels drawn from JS, you must use `compose` or `synthesize`. There is no way to inject a worklet into `Video.render` — that's a deliberate split, not an oversight.

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

Probe a video file. Returns container, codec, dimensions, frame rate, duration, audio presence, HDR, rotation, plus any `creationDate`, `location`, and `custom` metadata previously written by `Video.stamp` (or by another tool that wrote to the standard `udta` atoms).

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

End-past-EOF requests (`startSec + durationSec > source duration`) are silently clamped to the source's actual duration — matches `AVAssetExportSession` and ffmpeg leniency. This absorbs muxer-vs-encoder rounding drift (e.g. recorders that report a target duration ~10ms shorter than the bytes they actually wrote). Only `startSec` past EOF rejects with `InvalidSpec`.

### `Video.flip`

```ts
Video.flip(uri: string, options: FlipOptions): Promise<void>
```

Flip horizontally or vertically. Uses a rotation-flag remux when the container supports it (mp4 ↔ mov); transcodes otherwise.

### `Video.stamp`

```ts
Video.stamp(uri: string, options: StampOptions): Promise<void>
```

Add a watermark and/or write metadata. Metadata-only stamps remux (fast); a `watermark` falls into transcode. `StampOptions` is typed so that at least one of `watermark` or `metadata` is required at compile time:

```ts
type StampOptions = { outPath: string } & (
  | { watermark: Overlay; metadata?: MetadataSpec }
  | { watermark?: Overlay; metadata: MetadataSpec }
);
```

### `Video.render`

```ts
Video.render(spec: RenderSpec, options?: RenderOptions): Promise<void>
```

The full-spec native editing entry point — multi-clip concat, multiple overlays, custom encoder settings, mixed per-clip transforms, audio replacement, all in one decode/encode pass. The native side picks the cheapest path based on `spec`:

- All-passthrough spec (no overlays, no transforms beyond rotation flags) → **remux**
- Native-overlay or pixel-altering transform → **transcode**

`RenderSpec` requires a non-empty `clips` array at compile time — synthesized renders go through [`Video.synthesize`](#videosynthesize) instead.

`Video.render` does **not** do compose. To draw pixels from JS, use [`Video.compose`](#videocompose) (with source clips) or [`Video.synthesize`](#videosynthesize) (from scratch). See [Choosing a method](#choosing-a-method).

### `Video.compose`

```ts
Video.compose(spec: ComposeSpec, options: ComposeOptions): Promise<void>
```

Per-frame worklet drawing on top of source clips. The `options.drawFrame` callback runs on the Reanimated UI runtime once per output frame and writes pixels into a pre-allocated `FrameTarget`. The same `CVPixelBuffer` (iOS) / `AHardwareBuffer` (Android) is then handed to the encoder — no intermediate copy.

`drawFrame` must be a worklet. The recommended way to enforce this is the build-time [`babel-plugin-video-pipeline`](#worklet-directive-enforcement) check; without it, the first frame crashes at runtime with a directive-missing error.

Mix native overlays (`Overlay.Image`, `Overlay.Text`) freely on `spec.overlays`; they composite under your `drawFrame` output.

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

Builder functions for the two overlay variants. They normalize `anchor` presets (`'tl' | 'tr' | 'bl' | 'br' | 'center'`) into normalized `{ x, y }` points before crossing the Nitro boundary, which is why they exist as functions rather than plain object literals.

The normalized anchor is a **slot position within the free space** (output frame minus overlay): `(0, 0)` aligns the overlay's top-left with the frame's top-left; `(1, 1)` aligns its bottom-right with the frame's; `(0.5, 0.5)` centers it. Anchors always align corresponding edges — they do not address an arbitrary point on the overlay. Pixel-from-edge layouts can be expressed as `anchor.x = inset / (outputW - overlayW)`.

```ts
Overlay.Image({ uri, anchor, size, opacity?, timeRange? }): ImageOverlay
Overlay.Text({ text, style, anchor, timeRange? }): TextOverlay
```

Both variants are rendered natively (`CIFilter` + `CATextLayer` on iOS, Media3 `BitmapOverlay` + `TextOverlay` on Android). Advanced typography is intentionally out of scope; if you need pixel-identical cross-platform text, rasterize a PNG and use `Overlay.Image`.

For per-frame JS drawing, use [`Video.compose`](#videocompose) / [`Video.synthesize`](#videosynthesize) — they take `drawFrame` as a first-class argument, not as an overlay.

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
| `InvalidSpec`              | `InvalidSpecError`              | The spec or options object failed JS-side or native-side validation       |

`errorForCode(code, options?)` constructs the right subclass for a code — useful when relaying an error across boundaries.

`assertNever(x: never): never` is exported for exhaustiveness checks in consumer code that switches on a discriminated union from this library.

---

## Types

The full type list is exported from the package root and re-exported from the Nitro spec. The most load-bearing ones:

### `RenderSpec` and `ComposeSpec`

```ts
type NonEmptyArray<T> = [T, ...T[]];

interface RenderSpec {
  output: OutputSpec;
  clips: NonEmptyArray<ClipInput>;
  overlays?: Overlay[];     // Overlay.Image | Overlay.Text
  audio?: AudioSpec;
  metadata?: MetadataSpec;
}

interface ComposeSpec {
  output: OutputSpec;
  clips: NonEmptyArray<ClipInput>;
  overlays?: Overlay[];
  audio?: AudioSpec;
  metadata?: MetadataSpec;
}
```

Both facades require at least one clip at the type level — `Video.render` and `Video.compose` will not accept a clip-less spec. Synthesized renders (no clips, an explicit `duration`) go through `Video.synthesize` with its own [`SynthesizeOptions`](#videosynthesize) shape and the stricter `SynthesizeOutputSpec` below.

`RenderSpec` and `ComposeSpec` are structurally identical today. They are kept as distinct types so consumer code documents which execution path it targets — the underlying engines (native remux/transcode vs. the worklet compose pump) differ, and their public surfaces are free to diverge.

### `OutputSpec` and `SynthesizeOutputSpec`

```ts
interface OutputSpec {
  path: string;
  width?: number;
  height?: number;
  fps?: number;
  bitrate?: number;           // bits per second
  codec?: VideoCodec;         // 'h264' | 'hevc'; default 'h264'
  container?: VideoContainer; // 'mp4' | 'mov'
}

type SynthesizeOutputSpec = OutputSpec & {
  width: number;
  height: number;
  fps: number;
};
```

`Video.synthesize` requires `SynthesizeOutputSpec`; the three required fields are enforced at compile time.

#### Output file semantics

`path` is the on-disk destination for every operation that writes a file (`trim`, `flip`, `stamp`, `render`, `compose`, `synthesize`, `thumbnail`). The contract:

- **Form.** Must be a non-empty filesystem path or a `file://` URI. Other schemes (`http://`, `content://`, `data:`, …) are rejected at the JS boundary. Plain absolute paths and `file:///…` URIs are equivalent.
- **Overwrite.** If a file already exists at `path`, it is deleted before the new file is written. There is no `overwrite: false` option.
- **Parent directories.** Are **not** created automatically. The caller is responsible for ensuring the directory exists (e.g. via React Native's `RNFS.mkdir` or `expo-file-system`'s `makeDirectoryAsync`). Writing to a non-existent directory rejects with `IOError`.
- **Atomicity.** Writes are **not** atomic. While the operation is in flight, `path` may exist as a partial / not-yet-finalized file. Readers that observe the path mid-render will see incomplete data.
- **Failure / cancellation.** On rejection (any cause — `InvalidSpec`, `EncoderFailure`, `Cancelled`, …), the partial output at `path` is best-effort deleted by the native side. Don't rely on a partial file being present after a failed render.
- **Container vs. extension.** The output container is determined by `output.container` if provided, otherwise inferred from the file extension. There is no enforcement that `path`'s extension matches `output.container` — providing `path: 'out.mov'` with `container: 'mp4'` is accepted and produces an MP4 inside a `.mov` filename. Avoid relying on the extension alone for downstream tooling.

These semantics apply uniformly across iOS (AVFoundation) and Android (Media3 Transformer).

### `ClipInput` and `ClipTransform`

```ts
interface ClipInput {
  uri: string;
  startSec?: number;       // seconds into source; default 0
  durationSec?: number;    // seconds of source to use; default "rest of source"
  transform?: ClipTransform;
}

interface ClipTransform {
  rotate?: 0 | 90 | 180 | 270;
  flipH?: boolean;
  flipV?: boolean;
  crop?: { x: number; y: number; w: number; h: number }; // source-pixel coords
}
```

The timeline model is **concat-only**: clips are stitched end-to-end in array order. The first clip starts at output time `0`, the next picks up where it ended, and so on. There are no gaps and no overlaps; if you need either, render the segments separately and concat them.

When `durationSec` is omitted, the library calls `Video.info(uri)` to probe the source duration and uses `sourceDuration - startSec`. Provide `durationSec` explicitly to skip the probe.

The native Nitro boundary still receives `{ sourceStart, sourceDuration, outputStart }` — the library normalizes `ClipInput[]` into that shape before crossing. Direct consumers of the Nitro spec see the underlying form.

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

**When `onProgress` fires.** `Video.render`, `Video.compose`, and `Video.synthesize` always report progress when the operation decodes/encodes frames. For convenience methods, the rule is "transcode reports, remux doesn't":

| Operation                             | Underlying path | Reports progress? |
| ------------------------------------- | --------------- | ----------------- |
| `Video.trim`                          | remux           | No                |
| `Video.flip`                          | remux           | No (iOS); rejected with `InvalidSpec` on Android until the transcode fallback lands |
| `Video.stamp` (metadata only)         | remux           | No                |
| `Video.stamp` (with image watermark)  | transcode       | Yes               |

Remux paths complete in seconds and don't decode/encode individual frames, so per-frame progress is not meaningful — `onProgress` is accepted on the type for API uniformity and silently not invoked. If you need progress on these paths, the operation completes fast enough that just awaiting the promise is the right pattern.

### `MetadataSpec`

```ts
interface MetadataSpec {
  location?: { latitude: number; longitude: number }; // WGS-84
  software?: string;
  creationDate?: Date;
  description?: string;
  custom?: Record<string, string>;
}
```

`location` matches the standard media-metadata vocabulary (`AVMetadataCommonKeyLocation` on iOS, EXIF/IPTC GPSInfo, Photos.app UI). The TYPE is `WGS84Coordinate` to make the datum contract explicit — the source can be any GNSS constellation (GPS, GLONASS, Galileo, BeiDou, QZSS, …) or a non-satellite resolver corrected back to WGS-84. Container muxers serialize it to the standard `udta/©xyz` atom.

`custom` keys round-trip through the library — caller owns the keys; no namespace prefix is added.

### `AudioSpec`

```ts
type AudioSpec =
  | { mode: 'passthrough' }
  | { mode: 'mute' }
  | { mode: 'replace'; replaceUri: string };
```

Discriminated by `mode`, so `replaceUri` is required at compile time when (and only when) `mode === 'replace'`.

### `Size`

```ts
type Size = { w: number; h?: number } | { w?: number; h: number };
```

Used by `Overlay.Image`. At least one of `w` / `h` is required; the other scales proportionally.

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

Pixel-buffer handles backed by `CVPixelBuffer` (iOS) or `AHardwareBuffer` (Android). Both expose `width`, `height`, and `format: 'bgra8888' | 'rgba8888'`.

**Most consumers should not touch these directly.** Use one of the high-level helpers instead:

- `drawWithRGBA(draw)` — plain `Uint8Array` pixel writing. Stable, CPU-only, cross-platform.
- `drawWithSkia(draw)` (from `react-native-video-pipeline-skia`) — Skia drawing with automatic feature detection of the iOS Metal fast path. This is the recommended worklet entry point for anything beyond raw RGBA.

The remaining members of `FrameTarget` / `FrameSource` are advanced escape hatches:

| Member                                          | Stability    | Purpose                                                                                                                    |
| ----------------------------------------------- | ------------ | -------------------------------------------------------------------------------------------------------------------------- |
| `target.writeBytes(bytes)`                      | **Stable**   | `memcpy` of `width * height * 4` bytes into the target. Reached transparently by `drawWithRGBA`.                           |
| `target.unstable_bufferAddr` / `source.unstable_bufferAddr`       | Unstable | Raw native pointer (`bigint`). Used by `drawWithSkia` to hand the buffer to Skia. Pointer semantics are platform-specific.   |
| `target.unstable_blitFromNativeTexture(mtlTexturePtr)`            | Unstable | iOS-only Metal-to-buffer fast path. `drawWithSkia` feature-detects this and falls back to `writeBytes` on Android.           |
| `source.readBytes()`                                              | Stable   | Fresh RGBA8888 copy of the current source frame.                                                                             |

The `unstable_` prefix is the stability signal: those members are not covered by the v1.0 stability contract — pointer ABI may change, names may be moved under a dedicated namespace, or the surface may be removed in favor of a more portable signature. Building consumer code on top of them is supported, but prefer the high-level helpers (`drawWithRGBA`, `drawWithSkia`) so a future ABI change is invisible to your code.

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

Each top-level operation maps to one of three internal execution paths. The decision is made on the native side from the (loose) Nitro `VideoSpec` shape that crosses the boundary:

| Path        | When                                                                                | Speed   |
| ----------- | ----------------------------------------------------------------------------------- | ------- |
| **remux**   | Passthrough — no overlays, no per-pixel transforms, output codec/container match    | Fastest |
| **transcode** | Native-only overlays (`image`, `text`), transforms with `crop`/`flip`, codec change | Medium  |
| **compose** | Worklet overlay or `drawFrame` callback present, OR no source clips (synthesize)    | Slowest |

The `Video.trim` / `Video.flip` / `Video.stamp` convenience wrappers exist so the routing decision lives in C++, not split across JS and native. `Video.render` is the explicit form.

---

## Worklet directive enforcement

`Video.compose` and `Video.synthesize` accept callbacks that run on the Reanimated UI runtime. Reanimated requires every such function to begin with `'worklet';` so it can be lifted to the UI thread.

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
